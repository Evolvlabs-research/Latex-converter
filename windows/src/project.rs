// Un projet = un dossier : ses fichiers, le fichier ouvert (toujours enregistré), la compilation et SyncTeX.
// Pendant de Project.swift.
use crate::completion::{Sources, completion_sources};
use crate::history::{Snapshot, app_dir, flat, save_snapshot};
use crate::tex::*;
use std::{
    path::{Path, PathBuf},
    sync::{Arc, mpsc},
    thread,
    time::{Duration, Instant, SystemTime},
};

/// Lue sur le disque à chaque appel.
fn modification_date(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// Écrit d'un coup : un fichier temporaire remplace l'ancien, jamais de fichier à moitié écrit.
fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_file_name(format!(
        ".{}.nabla-tmp",
        path.file_name().unwrap_or_default().to_string_lossy()
    ));
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path).or_else(|_| {
        // Windows refuse de remplacer un fichier qu'un autre programme tient ouvert (antivirus, TeX) : écriture directe.
        let _ = std::fs::remove_file(&tmp);
        std::fs::write(path, text)
    })
}

pub enum Sync {
    Show(SyncBox),
    Reveal(String, usize),
}

pub struct Project {
    pub root: PathBuf,
    pub files: Vec<String>, // chemins relatifs, avec des « / »
    pub current: Option<String>,
    pub text: String,               // contenu du fichier ouvert, enregistré à chaque frappe
    pub load_gen: u64,              // change à chaque texte relu du disque : l'éditeur repart de zéro (et son annulation aussi)
    pub open_error: Option<String>, // fichier illisible (pas en UTF-8…) : affiché, jamais réécrit
    pub save_error: Option<String>,
    pub main: Option<String>,
    pub pdf: Option<Arc<Vec<u8>>>,
    pub log: Vec<LogItem>,
    pub duration: Option<Duration>,
    pub compiling: bool,
    pub outline: Vec<OutlineItem>,
    pub pending_line: Option<usize>, // ligne à montrer dès que le fichier demandé est affiché
    pub sync_box: Option<SyncBox>,   // à montrer dans le PDF
    ctx: egui::Context,
    pending: bool,
    compile_at: Option<Instant>,
    compile_rx: Option<mpsc::Receiver<(Build, Duration)>>,
    sync_tx: mpsc::Sender<Sync>,
    sync_rx: mpsc::Receiver<Sync>,
    known_date: Option<SystemTime>, // date du fichier ouvert la dernière fois qu'on l'a lu ou écrit
    next_snapshot: Instant,
    last_check: Instant,
}

impl Project {
    pub fn new(root: PathBuf, stored_main: Option<String>, ctx: egui::Context) -> Self {
        let (sync_tx, sync_rx) = mpsc::channel();
        let mut p = Project {
            root,
            files: vec![],
            current: None,
            text: String::new(),
            load_gen: 0,
            open_error: None,
            save_error: None,
            main: None,
            pdf: None,
            log: vec![],
            duration: None,
            compiling: false,
            outline: vec![],
            pending_line: None,
            sync_box: None,
            ctx,
            pending: false,
            compile_at: None,
            compile_rx: None,
            sync_tx,
            sync_rx,
            known_date: None,
            next_snapshot: Instant::now(),
            last_check: Instant::now(),
        };
        p.refresh();
        p.main = stored_main.filter(|m| p.files.contains(m)).or_else(|| p.guess_main());
        let first = p
            .main
            .clone()
            .or_else(|| p.files.iter().find(|f| TEXT_EXTENSIONS.contains(&ext(f).as_str())).cloned());
        p.open(first);
        p.compile();
        p
    }

    pub fn name(&self) -> String {
        self.root
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    }

    pub fn out_dir(&self) -> PathBuf {
        app_dir(true).join("build").join(flat(&self.root.to_string_lossy()))
    }

    pub fn output(&self, suffix: &str) -> Option<PathBuf> {
        self.main.as_ref().map(|m| self.out_dir().join(stem(m) + suffix))
    }

    pub fn path(&self, file: &str) -> PathBuf {
        project_file(&self.root, file)
    }

    pub fn errors(&self) -> usize {
        self.log.iter().filter(|i| i.kind == Kind::Error).count()
    }

    pub fn is_editing_text(&self) -> bool {
        self.current
            .as_ref()
            .is_some_and(|c| TEXT_EXTENSIONS.contains(&ext(c).as_str()))
            && self.open_error.is_none()
    }

    pub fn status(&self) -> String {
        if let Some(e) = &self.save_error {
            return e.clone();
        }
        if self.compiling {
            return "Compilation…".into();
        }
        match self.errors() {
            0 => {}
            1 => return "1 erreur".into(),
            n => return format!("{n} erreurs"),
        }
        let Some(d) = self.duration else { return String::new() };
        let time = format!("{:.1} s", d.as_secs_f64()).replace('.', ",");
        match self.log.len() {
            0 => format!("À jour · {time}"),
            1 => format!("À jour · {time} · 1 avertissement"),
            n => format!("À jour · {time} · {n} avertissements"),
        }
    }

    // MARK: Fichiers

    pub fn refresh(&mut self) {
        // shortcut: liste plate limitée à 2000 fichiers ; un arbre repliable si les projets grossissent.
        let mut found = Vec::new();
        let mut dirs = vec![self.root.clone()];
        while let Some(dir) = dirs.pop() {
            for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                if found.len() >= 2000 {
                    break;
                }
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') || is_hidden(&entry) {
                    continue;
                }
                let Ok(kind) = entry.file_type() else { continue };
                if kind.is_dir() {
                    dirs.push(entry.path());
                } else if kind.is_file() {
                    if let Some(rel) = relative_path(&entry.path().to_string_lossy(), &self.root) {
                        if !BUILD_EXTENSIONS.contains(&ext(&rel).as_str()) {
                            found.push(rel);
                        }
                    }
                }
            }
        }
        found.sort_by(|a, b| natural_cmp(a, b));
        self.files = found;
    }

    pub fn guess_main(&self) -> Option<String> {
        let tex: Vec<&String> = self.files.iter().filter(|f| ext(f) == "tex").collect();
        tex.iter()
            .find(|f| f.rsplit('/').next() == Some("main.tex"))
            .or_else(|| {
                tex.iter()
                    .find(|f| std::fs::read_to_string(self.path(f)).is_ok_and(|t| t.contains("\\documentclass")))
            })
            .map(|f| f.to_string())
    }

    pub fn set_main(&mut self, file: Option<String>) {
        self.main = file;
        self.compile();
    }

    pub fn open(&mut self, file: Option<String>) {
        self.current = file.clone();
        self.open_error = None;
        self.text.clear();
        self.load_gen += 1;
        let Some(file) = file.filter(|f| TEXT_EXTENSIONS.contains(&ext(f).as_str())) else {
            return;
        };
        let path = self.path(&file);
        match std::fs::read(&path).map(String::from_utf8) {
            Ok(Ok(text)) => self.text = text,
            _ => {
                self.open_error = Some(format!(
                    "« {file} » n'est pas un texte UTF-8 lisible : il n'est pas modifié ici."
                ));
                return;
            }
        }
        self.known_date = modification_date(&path);
        save_snapshot(&self.text, &self.root, &file, Duration::ZERO, SystemTime::now()); // l'état d'avant la séance
        self.next_snapshot = Instant::now() + Duration::from_secs(120);
    }

    /// Le texte vient de changer dans l'éditeur : il est écrit sur le disque, rien à perdre en quittant.
    pub fn edited(&mut self) {
        let Some(current) = self.current.clone().filter(|_| self.is_editing_text()) else {
            return;
        };
        let path = self.path(&current);
        // Modifié ailleurs depuis notre dernière lecture : on garde la version du disque, la nôtre va dans l'historique.
        if modification_date(&path) != self.known_date {
            if let Ok(disk) = std::fs::read_to_string(&path) {
                if disk != self.text {
                    save_snapshot(&self.text, &self.root, &current, Duration::ZERO, SystemTime::now());
                    self.text = disk;
                    self.load_gen += 1;
                    self.known_date = modification_date(&path);
                    self.save_error = Some(format!(
                        "« {current} » a été modifié ailleurs : version du disque rechargée, la vôtre est dans l'historique."
                    ));
                    self.schedule_compile();
                    return;
                }
            }
        }
        match write_atomic(&path, &self.text) {
            Ok(()) => {
                self.known_date = modification_date(&path);
                self.save_error = None;
            }
            Err(e) => self.save_error = Some(format!("Enregistrement impossible : {e}")),
        }
        if Instant::now() >= self.next_snapshot {
            // une version toutes les 2 minutes de travail
            save_snapshot(&self.text, &self.root, &current, Duration::from_secs(120), SystemTime::now());
            self.next_snapshot = Instant::now() + Duration::from_secs(120);
        }
        self.schedule_compile();
    }

    /// Relit le fichier ouvert s'il a changé sur le disque depuis notre dernière lecture ou écriture.
    pub fn check_disk(&mut self) {
        let Some(current) = self.current.clone().filter(|_| self.is_editing_text()) else {
            return;
        };
        let path = self.path(&current);
        let date = modification_date(&path);
        if date == self.known_date {
            return;
        }
        self.known_date = date;
        if let Ok(disk) = std::fs::read_to_string(&path) {
            if disk != self.text {
                self.text = disk;
                self.load_gen += 1;
                self.schedule_compile();
            }
        }
    }

    /// Au retour dans l'app : nouveaux fichiers, et fichier ouvert modifié par un autre éditeur.
    pub fn reload(&mut self) {
        self.refresh();
        if self.current.as_ref().is_some_and(|c| !self.files.contains(c)) {
            self.open(None);
        }
        self.check_disk();
    }

    /// Remet une ancienne version ; la version actuelle part d'abord dans l'historique.
    pub fn restore(&mut self, snapshot: &Snapshot) {
        let Some(current) = self.current.clone() else { return };
        save_snapshot(&self.text, &self.root, &current, Duration::ZERO, SystemTime::now());
        self.text = snapshot.text();
        self.load_gen += 1;
        self.edited();
    }

    pub fn create_file(&mut self, input: &str) -> Result<(), String> {
        let name = input.trim();
        let mut path = child_path(name, &self.root).ok_or_else(|| format!("Nom invalide : « {name} »."))?;
        if path.extension().is_none() {
            path.set_extension("tex");
        }
        if path.exists() {
            return Err(format!("« {name} » existe déjà."));
        }
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::write(&path, "").map_err(|e| e.to_string())?;
        self.refresh();
        self.open(relative_path(&path.to_string_lossy(), &self.root));
        Ok(())
    }

    /// Copie des fichiers dans le projet, sans jamais écraser : « image 2.png » si « image.png » existe.
    pub fn import_files(&mut self, paths: &[PathBuf]) {
        for src in paths
            .iter()
            .filter(|p| relative_path(&p.to_string_lossy(), &self.root).is_none())
        {
            let Some(name) = src.file_name() else { continue };
            let stem = src.file_stem().unwrap_or_default().to_string_lossy();
            let suffix = src
                .extension()
                .map(|e| format!(".{}", e.to_string_lossy()))
                .unwrap_or_default();
            let mut dest = self.root.join(name);
            let mut n = 2;
            while dest.exists() {
                dest = self.root.join(format!("{stem} {n}{suffix}"));
                n += 1;
            }
            let _ = std::fs::copy(src, &dest);
        }
        self.refresh();
    }

    /// Placer dans la corbeille : récupérable, jamais supprimé définitivement.
    pub fn trash(&mut self, file: &str) {
        let _ = trash::delete(self.path(file));
        self.refresh();
        if self.current.as_deref() == Some(file) {
            self.open(None);
        }
        if self.main.as_deref() == Some(file) {
            let main = self.guess_main();
            self.set_main(main);
        }
    }

    // MARK: Compilation

    /// Recompile quand on arrête de taper.
    pub fn schedule_compile(&mut self) {
        self.compile_at = Some(Instant::now() + Duration::from_millis(800));
        self.ctx.request_repaint_after(Duration::from_millis(800));
    }

    pub fn compile(&mut self) {
        self.compile_at = None;
        let Some(main) = self.main.clone() else {
            self.log = vec![LogItem::new(
                Kind::Error,
                "Aucun document principal : ajoutez un fichier .tex avec \\documentclass.",
            )];
            return;
        };
        if self.compiling {
            self.pending = true; // une seule compilation à la fois dans le même dossier
            return;
        }
        self.compiling = true;
        let root = self.root.clone();
        self.outline = document_outline(&main, &|f| std::fs::read_to_string(project_file(&root, f)).ok());
        let (tx, rx) = mpsc::channel();
        self.compile_rx = Some(rx);
        let (out, ctx) = (self.out_dir(), self.ctx.clone());
        thread::spawn(move || {
            let start = Instant::now();
            let build = latexmk(&root, &main, &out);
            let _ = tx.send((build, start.elapsed()));
            ctx.request_repaint();
        });
    }

    /// À chaque image : résultats de compilation et de SyncTeX, compilation différée, disque surveillé.
    pub fn poll(&mut self, focused: bool) {
        if let Some(Ok((build, duration))) = self.compile_rx.as_ref().map(|rx| rx.try_recv()) {
            self.compile_rx = None;
            if let Some(pdf) = build.pdf {
                self.pdf = Some(Arc::new(pdf));
            }
            self.log = build.log;
            self.duration = Some(duration);
            self.compiling = false;
            if std::mem::take(&mut self.pending) {
                self.compile();
            }
        }
        while let Ok(sync) = self.sync_rx.try_recv() {
            match sync {
                Sync::Show(b) => self.sync_box = Some(b),
                Sync::Reveal(file, line) => self.reveal(Some(&file), Some(line)),
            }
        }
        if let Some(at) = self.compile_at {
            if Instant::now() >= at {
                self.compile();
            } else {
                self.ctx.request_repaint_after(at - Instant::now());
            }
        }
        // Un autre éditeur ou Git peut modifier le fichier ouvert ; au premier plan seulement.
        if focused {
            if self.last_check.elapsed() >= Duration::from_secs(1) {
                self.last_check = Instant::now();
                self.check_disk();
            }
            self.ctx.request_repaint_after(Duration::from_secs(1));
        }
    }

    // MARK: SyncTeX

    /// Fait défiler le PDF jusqu'à la ligne `line` du fichier ouvert.
    pub fn show_in_pdf(&self, line: usize) {
        let (Some(current), Some(pdf)) = (self.current.clone(), self.output(".pdf")) else {
            return;
        };
        let (root, tx, ctx) = (self.root.clone(), self.sync_tx.clone(), self.ctx.clone());
        thread::spawn(move || {
            if let Some(b) = synctex_view(&pdf, &current, line, &root) {
                let _ = tx.send(Sync::Show(b));
                ctx.request_repaint();
            }
        });
    }

    /// Double-clic dans le PDF (page à partir de 1, points depuis le haut gauche) : ouvre la source à la bonne ligne.
    pub fn show_in_source(&self, page: usize, x: f32, y: f32) {
        let Some(pdf) = self.output(".pdf") else { return };
        let (root, tx, ctx) = (self.root.clone(), self.sync_tx.clone(), self.ctx.clone());
        thread::spawn(move || {
            if let Some((file, line)) = synctex_edit(&pdf, page, x, y, &root) {
                let _ = tx.send(Sync::Reveal(file, line));
                ctx.request_repaint();
            }
        });
    }

    pub fn reveal(&mut self, file: Option<&str>, line: Option<usize>) {
        let Some(file) = file.filter(|f| self.files.iter().any(|x| x == f)) else {
            return;
        };
        if self.current.as_deref() != Some(file) {
            self.open(Some(file.to_string()));
        }
        self.pending_line = line;
    }

    // MARK: Complétion

    pub fn sources(&self) -> Sources {
        let files: Vec<(String, String)> = self
            .files
            .iter()
            .filter(|f| ["tex", "bib"].contains(&ext(f).as_str()))
            .filter_map(|f| Some((f.clone(), std::fs::read_to_string(self.path(f)).ok()?)))
            .collect();
        completion_sources(&files)
    }
}

#[cfg(windows)]
fn is_hidden(entry: &std::fs::DirEntry) -> bool {
    use std::os::windows::fs::MetadataExt;
    entry.metadata().is_ok_and(|m| m.file_attributes() & 0x2 != 0) // FILE_ATTRIBUTE_HIDDEN
}

#[cfg(not(windows))]
fn is_hidden(_: &std::fs::DirEntry) -> bool {
    false
}

/// Ordre de l'Explorateur : « chap2 » avant « chap10 », sans tenir compte des majuscules.
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let num = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut s = String::new();
                    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
                        s.push(c);
                        it.next();
                    }
                    s.trim_start_matches('0').to_string()
                };
                let (n, m) = (num(&mut a), num(&mut b));
                let o = n.len().cmp(&m.len()).then(n.cmp(&m));
                if o.is_ne() {
                    return o;
                }
            }
            (Some(x), Some(y)) => {
                let o = x.to_lowercase().cmp(y.to_lowercase());
                if o.is_ne() {
                    return o;
                }
                a.next();
                b.next();
            }
        }
    }
}
