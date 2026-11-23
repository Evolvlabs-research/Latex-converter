// Outils en ligne de commande : latexmk (compilation) et synctex (lien source <-> PDF). Pendant de TeX.swift.
use regex::Regex;
use std::{
    io::Read,
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
    sync::{LazyLock, mpsc},
    thread,
    time::{Duration, SystemTime},
};

include!(concat!(env!("OUT_DIR"), "/shared.rs"));

pub struct Template {
    #[allow(dead_code)] // identifiant du modèle, utilisé par les tests
    pub id: &'static str,
    pub name: &'static str,
    pub detail: &'static str, // à quoi il sert, en une ligne sous le nom
    pub main: &'static str,
}

pub const TEXT_EXTENSIONS: &[&str] = &["tex", "bib", "sty", "cls", "bst", "txt", "md", "cfg", "def", "ltx"];
pub const BUILD_EXTENSIONS: &[&str] = &[
    "aux",
    "log",
    "out",
    "toc",
    "lof",
    "lot",
    "fls",
    "fdb_latexmk",
    "gz",
    "bbl",
    "blg",
    "bcf",
    "xdv",
    "nav",
    "snm",
];

pub fn ext(path: &str) -> String {
    Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap()
}

// MARK: - Outils

/// Où chercher LaTeX en plus du PATH : une app lancée depuis l'Explorateur juste après l'installation
/// de MiKTeX ou de TeX Live n'a pas encore le nouveau PATH.
static TEX_DIRS: LazyLock<Vec<PathBuf>> = LazyLock::new(|| {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    if cfg!(windows) {
        for var in ["LOCALAPPDATA", "ProgramFiles"] {
            if let Some(base) = std::env::var_os(var) {
                let base = PathBuf::from(base);
                dirs.push(base.join(if var == "LOCALAPPDATA" {
                    "Programs/MiKTeX/miktex/bin/x64"
                } else {
                    "MiKTeX/miktex/bin/x64"
                }));
            }
        }
        // TeX Live : C:\texlive\2026\bin\windows (win32 ou win64 avant 2023), l'année la plus récente d'abord.
        let mut years: Vec<PathBuf> = std::fs::read_dir("C:\\texlive")
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .collect();
        years.sort_by(|a, b| b.cmp(a));
        for year in years {
            for bin in ["windows", "win64", "win32"] {
                dirs.push(year.join("bin").join(bin));
            }
        }
    } else {
        dirs.extend(["/opt/homebrew/bin", "/Library/TeX/texbin", "/usr/local/bin", "/usr/bin"].map(PathBuf::from));
    }
    dirs
});

pub fn find_tool(name: &str) -> Option<PathBuf> {
    let file = if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    };
    TEX_DIRS.iter().map(|d| d.join(&file)).find(|p| p.is_file())
}

/// Ce qui manque pour compiler : rien, latexmk, Perl (le latexmk de MiKTeX en a besoin), ou LaTeX tout entier.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum TeXSetup {
    Ready,
    MissingLatexmk,
    MissingPerl,
    MissingTeX,
}

pub fn tex_setup() -> TeXSetup {
    match find_tool("latexmk") {
        Some(p) if cfg!(windows) && p.to_string_lossy().to_lowercase().contains("miktex") && find_tool("perl").is_none() => {
            TeXSetup::MissingPerl
        }
        Some(_) => TeXSetup::Ready,
        None if find_tool("pdflatex").is_some() => TeXSetup::MissingLatexmk,
        None => TeXSetup::MissingTeX,
    }
}

pub const MIKTEX_URL: &str = "https://miktex.org/download";
pub const PERL_URL: &str = "https://strawberryperl.com";

/// Lance un programme, rend son code de sortie et sa sortie. Arrêté au bout de `timeout`.
pub fn run(exe: &Path, args: &[&str], dir: &Path, timeout: Duration) -> (i32, String) {
    let mut cmd = Command::new(exe);
    cmd.args(args)
        .current_dir(dir)
        .env("PATH", std::env::join_paths(TEX_DIRS.iter()).unwrap_or_default()) // latexmk appelle pdflatex, bibtex…
        .env("max_print_line", "10000") // journal TeX sans lignes coupées à 79 caractères
        .stdin(Stdio::null()) // TeX ne reste jamais bloqué sur une question
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW : pas de console qui s'ouvre à chaque compilation
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (-1, e.to_string()),
    };
    let pid = child.id();
    let (done, finished) = mpsc::channel::<()>();
    thread::spawn(move || {
        // une boucle infinie en TeX ne bloque pas l'app : on arrête le programme et ce qu'il a lancé
        if finished.recv_timeout(timeout) == Err(mpsc::RecvTimeoutError::Timeout) {
            kill_tree(pid);
        }
    });
    let mut err = child.stderr.take().unwrap();
    let err_reader = thread::spawn(move || {
        let mut s = Vec::new();
        let _ = err.read_to_end(&mut s);
        s
    });
    let mut out = Vec::new();
    let _ = child.stdout.take().unwrap().read_to_end(&mut out);
    out.extend(err_reader.join().unwrap_or_default());
    let status = child.wait().map(|s| s.code().unwrap_or(-1)).unwrap_or(-1);
    let _ = done.send(());
    (status, String::from_utf8_lossy(&out).into_owned())
}

fn kill_tree(pid: u32) {
    let pid = pid.to_string();
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = Command::new("taskkill")
            .args(["/PID", &pid, "/T", "/F"])
            .creation_flags(0x0800_0000)
            .status();
    }
    #[cfg(not(windows))]
    {
        let _ = Command::new("pkill").args(["-TERM", "-P", &pid]).status();
        let _ = Command::new("kill").args(["-TERM", &pid]).status();
    }
}

// MARK: - Compilation

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Kind {
    Error,
    Warning,
}

#[derive(Clone, PartialEq, Eq, Debug, Hash)]
pub struct LogItem {
    pub kind: Kind,
    pub file: Option<String>, // relatif au projet ; None si inconnu ou hors du projet
    pub line: Option<usize>,
    pub message: String,
}

impl LogItem {
    pub fn new(kind: Kind, message: impl Into<String>) -> Self {
        LogItem {
            kind,
            file: None,
            line: None,
            message: message.into(),
        }
    }
}

pub struct Build {
    pub pdf: Option<Vec<u8>>,
    pub log: Vec<LogItem>,
}

/// Nom du fichier sans dossier ni extension : « chap/main.tex » -> « main ».
pub fn stem(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Compile `main` (chemin relatif) depuis la racine du projet ; les fichiers produits vont dans `out_dir`.
pub fn latexmk(root: &Path, main: &str, out_dir: &Path) -> Build {
    let Some(tool) = find_tool("latexmk") else {
        let message = match tex_setup() {
            TeXSetup::MissingLatexmk => {
                "latexmk manque à votre installation de LaTeX : installez le paquet latexmk (console MiKTeX › Paquets, ou tlmgr install latexmk)."
            }
            _ => "LaTeX n'est pas installé sur ce PC. Installez MiKTeX (miktex.org) ou TeX Live, puis recompilez.",
        };
        return Build {
            pdf: None,
            log: vec![LogItem::new(Kind::Error, message)],
        };
    };
    let _ = std::fs::create_dir_all(out_dir);
    let name = stem(main);
    let source = std::fs::read_to_string(root.join(main)).unwrap_or_default();
    let outdir = format!("-outdir={}", out_dir.display());
    // -norc : un latexmkrc livré avec un projet pourrait lancer n'importe quel programme.
    let args = [
        "-norc",
        engine_flag(&source),
        "-interaction=nonstopmode",
        "-synctex=1",
        "-file-line-error",
        &outdir,
        main,
    ];
    let start = SystemTime::now();
    let (status, out) = run(&tool, &args, root, Duration::from_secs(120));
    let log_path = out_dir.join(format!("{name}.log"));
    // Échec sans nouveau journal (MiKTeX bloqué…) : l'ancien montrerait des erreurs déjà corrigées.
    let fresh = status == 0
        || std::fs::metadata(&log_path)
            .and_then(|m| m.modified())
            .is_ok_and(|t| t >= start);
    let log_text = if fresh {
        std::fs::read(&log_path).unwrap_or_default()
    } else {
        Vec::new()
    };
    let mut log = parse_log(&String::from_utf8_lossy(&log_text), root);
    if status != 0 && !log.iter().any(|i| i.kind == Kind::Error) {
        log.insert(0, LogItem::new(Kind::Error, failure_message(&out)));
    }
    Build {
        pdf: std::fs::read(out_dir.join(format!("{name}.pdf"))).ok(),
        log,
    }
}

/// Échec sans erreur dans le journal TeX : la dernière ligne de latexmk, et quoi faire quand on le sait.
pub fn failure_message(out: &str) -> String {
    // MiKTeX tout juste installé refuse de lancer ses programmes tant qu'on n'a pas cherché ses mises à jour.
    // Deux textes : « no MiKTeX administrator has checked for updates » et « you have not checked for MiKTeX updates ».
    if out.contains("major issue") && out.contains("updates") {
        // La console MiKTeX n'existe qu'en anglais : on cite ses libellés tels quels.
        return "MiKTeX demande une recherche de mises à jour avant de compiler : ouvrez la console MiKTeX, \
                onglet Updates, bouton Check for updates, puis recompilez."
            .into();
    }
    // Sous Windows, latexmk finit toujours par « Reverting Windows console CPs… » : ce n'est pas la cause.
    let last = out
        .lines()
        .map(str::trim)
        .rev()
        .find(|l| !l.is_empty() && !l.starts_with("Reverting Windows console"))
        .unwrap_or("");
    let hint = if out.contains("perl") && cfg!(windows) {
        " Le latexmk de MiKTeX a besoin de Perl (strawberryperl.com)."
    } else {
        ""
    };
    format!("La compilation a échoué. {last}{hint}")
}

/// Moteur choisi par le commentaire « % !TEX program = xelatex », comme dans TeXShop et Overleaf.
pub fn engine_flag(source: &str) -> &'static str {
    static RE: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)%\s*!TEX\s+(?:TS-)?program\s*=\s*(\w+)"));
    match RE.captures(source).map(|c| c[1].to_lowercase()).as_deref() {
        Some("xelatex") => "-pdfxe",
        Some("lualatex") => "-pdflua",
        _ => "-pdf",
    }
}

/// Erreurs (format -file-line-error : « ./chap/a.tex:4: message ») et avertissements du journal TeX.
pub fn parse_log(log: &str, root: &Path) -> Vec<LogItem> {
    static ERROR: LazyLock<Regex> = LazyLock::new(|| re(r"^(.+?\.\w+):(\d+): (.+)$"));
    static WARNING: LazyLock<Regex> =
        LazyLock::new(|| re(r"^(?:LaTeX|Package \w+|Class \w+) Warning: (.+?)(?: on input line (\d+))?\.?$"));
    let lines: Vec<&str> = log
        .split('\n')
        .map(|l| l.trim_end_matches('\r'))
        .filter(|l| !l.is_empty())
        .collect();
    let mut items = Vec::new();
    let mut cause: Option<&str> = None; // dernière ligne « ! … » : la vraie raison d'un « Emergency stop »
    for line in &lines {
        if let Some(rest) = line.strip_prefix("! ") {
            cause = Some(rest);
        } else if let Some(m) = ERROR.captures(line) {
            let mut message = m[3].to_string();
            if message.contains("==> Fatal error") {
                continue; // répète l'erreur précédente
            }
            if message == "Emergency stop." {
                if let Some(cause) = cause {
                    message = cause.to_string();
                }
            }
            items.push(LogItem {
                kind: Kind::Error,
                file: relative_path(&m[1], root),
                line: m[2].parse().ok(),
                message: explain(&message),
            });
        } else if let Some(m) = WARNING.captures(line) {
            items.push(LogItem {
                kind: Kind::Warning,
                file: None,
                line: m.get(2).and_then(|l| l.as_str().parse().ok()),
                message: m[1].to_string(),
            });
        }
    }
    if !items.iter().any(|i| i.kind == Kind::Error) {
        // erreurs sans fichier ni ligne
        items.extend(
            lines
                .iter()
                .filter_map(|l| l.strip_prefix("! "))
                .filter(|l| !l.contains("==> Fatal error"))
                .map(|l| LogItem::new(Kind::Error, explain(l))),
        );
    }
    items
}

/// Message TeX rendu compréhensible quand on sait quoi faire.
pub fn explain(message: &str) -> String {
    static NOT_FOUND: LazyLock<Regex> = LazyLock::new(|| re(r"File `([^']+)' not found"));
    match NOT_FOUND.captures(message) {
        Some(m) => format!(
            "Fichier « {} » introuvable : ajoutez-le au projet (+ › Importer des fichiers) ou installez le paquet qui le fournit.",
            &m[1]
        ),
        None => message.to_string(),
    }
}

/// Chemin sans « . » ni « .. », liens résolus quand le fichier existe.
fn normalize(path: &Path) -> PathBuf {
    if let Ok(p) = path.canonicalize() {
        // Windows : canonicalize rend « \\?\C:\… », que ne donnent ni TeX ni l'Explorateur.
        let s = p.to_string_lossy();
        return s.strip_prefix(r"\\?\").map(PathBuf::from).unwrap_or(p);
    }
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            c => out.push(c),
        }
    }
    out
}

/// Chemin relatif au projet, avec des « / » (« ./chap/a.tex » ou chemin absolu dedans) ; None s'il est hors du projet.
pub fn relative_path(path: &str, root: &Path) -> Option<String> {
    let p = Path::new(path);
    let full = normalize(&if p.is_absolute() { p.to_path_buf() } else { root.join(p) });
    let base = normalize(root);
    let rel = match full.strip_prefix(&base) {
        Ok(r) => r.to_path_buf(),
        Err(_) => {
            // Windows : « c:\Users » et « C:\Users » sont le même dossier
            let (f, b) = (full.to_string_lossy().into_owned(), base.to_string_lossy().to_lowercase());
            let rest = f
                .get(b.len()..)
                .filter(|_| cfg!(windows) && f.to_lowercase().starts_with(&b))?;
            PathBuf::from(rest.strip_prefix(['\\', '/'])?)
        }
    };
    let parts: Vec<String> = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    (!parts.is_empty()).then(|| parts.join("/"))
}

/// Fichier du projet à partir d'un nom saisi ; None s'il sortirait du dossier (« ../ », chemin absolu).
pub fn child_path(name: &str, root: &Path) -> Option<PathBuf> {
    let mut parts: Vec<&std::ffi::OsStr> = Vec::new();
    for c in Path::new(name).components() {
        match c {
            Component::Normal(s) => parts.push(s),
            Component::CurDir => {}
            Component::ParentDir => {
                parts.pop()?;
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    if name.starts_with('/') || name.starts_with('\\') || parts.is_empty() {
        return None;
    }
    Some(parts.iter().fold(root.to_path_buf(), |p, s| p.join(s)))
}

/// Chemin sur le disque d'un fichier du projet (chemin relatif avec des « / »).
pub fn project_file(root: &Path, rel: &str) -> PathBuf {
    rel.split('/').fold(root.to_path_buf(), |p, s| p.join(s))
}

/// Crée un dossier de projet avec main.tex ; refuse un dossier qui existe déjà (rien n'est écrasé).
pub fn create_project(path: &Path, template: &str) -> Result<(), String> {
    if path.exists() {
        return Err(format!(
            "« {} » existe déjà.",
            path.file_name().unwrap_or_default().to_string_lossy()
        ));
    }
    std::fs::create_dir(path)
        .and_then(|_| std::fs::write(path.join("main.tex"), template))
        .map_err(|e| e.to_string())
}

// MARK: - SyncTeX

/// Valeur de « Clé:valeur » dans la sortie de synctex (premier résultat).
fn synctex_field<'a>(out: &'a str, key: &str) -> Option<&'a str> {
    out.lines()
        .find_map(|l| l.trim_end_matches('\r').strip_prefix(key)?.strip_prefix(':'))
}

/// Point du PDF (page à partir de 1, x et y depuis le haut gauche, en points) -> fichier et ligne.
pub fn synctex_edit(pdf: &Path, page: usize, x: f32, y: f32, root: &Path) -> Option<(String, usize)> {
    let tool = find_tool("synctex")?;
    let arg = format!("{page}:{x}:{y}:{}", pdf.display());
    let (_, out) = run(&tool, &["edit", "-o", &arg], root, Duration::from_secs(20));
    let file = relative_path(synctex_field(&out, "Input")?, root)?;
    Some((file, synctex_field(&out, "Line")?.trim().parse().ok()?))
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SyncBox {
    pub page: usize, // à partir de 1
    pub x: f32,
    pub y: f32, // ligne de base, depuis le haut
    pub width: f32,
    pub height: f32,
}

/// Ligne d'un fichier -> page et boîte dans le PDF.
pub fn synctex_view(pdf: &Path, file: &str, line: usize, root: &Path) -> Option<SyncBox> {
    let tool = find_tool("synctex")?;
    let full = project_file(root, file).to_string_lossy().into_owned();
    // synctex compare le nom à celui du \input : chemin complet d'abord, puis relatif au projet.
    for name in [full.as_str(), file] {
        let input = format!("{line}:1:{name}");
        let (_, out) = run(
            &tool,
            &["view", "-i", &input, "-o", &pdf.to_string_lossy()],
            root,
            Duration::from_secs(20),
        );
        let num = |k: &str| synctex_field(&out, k).and_then(|v| v.trim().parse::<f32>().ok());
        if let (Some(page), Some(x), Some(y)) = (num("Page"), num("h"), num("v")) {
            return Some(SyncBox {
                page: page as usize,
                x,
                y,
                width: num("W").unwrap_or(0.0),
                height: num("H").unwrap_or(0.0),
            });
        }
    }
    None
}

// MARK: - Plan du document

#[derive(Clone, PartialEq, Eq, Debug, Hash)]
pub struct OutlineItem {
    pub level: usize, // 0 partie, 1 chapitre, 2 section, 3 sous-section, 4 sous-sous-section
    pub title: String,
    pub file: String,
    pub line: usize,
}

/// Ligne sans « \verb|…| » (son contenu n'est pas du LaTeX).
fn strip_verb(line: &str) -> String {
    let mut out = String::new();
    let mut rest = line;
    while let Some(i) = rest.find("\\verb") {
        out += &rest[..i];
        let after = rest[i + 5..].strip_prefix('*').unwrap_or(&rest[i + 5..]);
        match after.chars().next() {
            Some(d) if !d.is_ascii_alphabetic() && !d.is_whitespace() => match after[d.len_utf8()..].find(d) {
                Some(end) => rest = &after[d.len_utf8() + end + d.len_utf8()..],
                None => return out + &rest[i..],
            },
            _ => {
                out += "\\verb";
                rest = &rest[i + 5..];
            }
        }
    }
    out + rest
}

/// Titres dans l'ordre de lecture, en suivant les \input et \include depuis `file`.
pub fn document_outline(file: &str, read: &dyn Fn(&str) -> Option<String>) -> Vec<OutlineItem> {
    outline_at(file, read, 0)
}

fn outline_at(file: &str, read: &dyn Fn(&str) -> Option<String>, depth: usize) -> Vec<OutlineItem> {
    static VERBATIM: LazyLock<Regex> = LazyLock::new(|| re(r"\\begin\{(verbatim\*?|Verbatim|lstlisting|minted|comment)\}"));
    static COMMENT: LazyLock<Regex> = LazyLock::new(|| re(r"(^|[^\\])((?:\\\\)*)%.*"));
    static COMMAND: LazyLock<Regex> =
        LazyLock::new(|| re(r"\\(part|chapter|section|subsection|subsubsection|input|include)\*?(?:\[[^\]]*\])?\{"));
    let Some(text) = (depth < 10).then(|| read(file)).flatten() else {
        return vec![];
    };
    let mut items = Vec::new();
    let mut verbatim: Option<String> = None; // environnement verbatim en cours : son contenu n'est pas du LaTeX
    for (i, raw) in text.split('\n').enumerate() {
        if let Some(env) = &verbatim {
            if raw.contains(&format!("\\end{{{env}}}")) {
                verbatim = None;
            }
            continue;
        }
        if let Some(m) = VERBATIM.captures(raw) {
            verbatim = Some(m[1].to_string());
            continue;
        }
        let line = strip_verb(raw.trim_end_matches('\r'));
        let line = COMMENT.replace(&line, "$1$2"); // sans commentaire ; « \% » reste, « \\% » commente
        for m in COMMAND.captures_iter(&line) {
            let Some(arg) = balanced_argument(&line[m.get(0).unwrap().end()..]) else {
                continue;
            };
            let command = &m[1];
            if command == "input" || command == "include" {
                let path = if ext(arg).is_empty() {
                    format!("{arg}.tex")
                } else {
                    arg.to_string()
                };
                let path: Vec<&str> = path.split('/').filter(|p| *p != "." && !p.is_empty()).collect();
                items.extend(outline_at(&path.join("/"), read, depth + 1));
            } else {
                let level = ["part", "chapter", "section", "subsection", "subsubsection"]
                    .iter()
                    .position(|c| *c == command)
                    .unwrap_or(2);
                items.push(OutlineItem {
                    level,
                    title: arg.to_string(),
                    file: file.to_string(),
                    line: i + 1,
                });
            }
        }
    }
    items
}

/// Contenu d'un argument jusqu'à l'accolade fermante qui lui correspond (les {} imbriquées sont gardées).
pub fn balanced_argument(text: &str) -> Option<&str> {
    let mut depth = 1;
    for (i, c) in text.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[..i]);
                }
            }
            _ => {}
        }
    }
    None
}
