// Nabla pour Windows : projets LaTeX compilés sur ce PC. Pendant de App.swift et ProjectView.swift.
#![cfg_attr(not(test), windows_subsystem = "windows")] // pas de console derrière la fenêtre

mod completion;
mod editor;
mod history;
mod pdf;
mod project;
mod tex;

#[cfg(test)]
mod tests;

use editor::{DEFAULT_FONT_SIZE, Editor, FONT_SIZES};
use egui::{Align, Color32, Key, KeyboardShortcut, Layout, Modifiers, RichText, vec2};
use history::{Snapshot, snapshots};
use project::Project;
use std::{collections::HashMap, path::PathBuf};
use tex::{Kind, TEMPLATES, TeXSetup, ext};

fn main() -> eframe::Result {
    let icon = eframe::icon_data::from_png_bytes(include_bytes!("../assets/icon.png")).unwrap_or_default();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Nabla")
            .with_icon(icon)
            .with_inner_size([1320.0, 820.0])
            .with_min_inner_size([900.0, 540.0])
            .with_drag_and_drop(true),
        persist_window: true,
        ..Default::default()
    };
    eframe::run_native("Nabla", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}

// MARK: - Réglages

struct Settings {
    recents: Vec<String>,           // derniers projets, le plus récent d'abord
    mains: HashMap<String, String>, // document principal de chaque projet
    font_size: f32,
    invert: bool,       // PDF en sombre : aperçu et export
    appearance: String, // "system", "light" ou "dark"
}

impl Settings {
    fn load(storage: Option<&dyn eframe::Storage>) -> Self {
        let get = |k: &str| storage.and_then(|s| s.get_string(k)).unwrap_or_default();
        Settings {
            recents: get("recents").lines().map(str::to_string).collect(),
            mains: get("mains")
                .lines()
                .filter_map(|l| l.split_once('\t'))
                .map(|(a, b)| (a.into(), b.into()))
                .collect(),
            font_size: get("fontSize")
                .parse()
                .unwrap_or(DEFAULT_FONT_SIZE)
                .clamp(FONT_SIZES.start, FONT_SIZES.end),
            invert: get("invertPDF") == "true",
            appearance: Some(get("appearance"))
                .filter(|a| a == "light" || a == "dark")
                .unwrap_or("system".into()),
        }
    }

    fn save(&self, s: &mut dyn eframe::Storage) {
        s.set_string("recents", self.recents.join("\n"));
        s.set_string(
            "mains",
            self.mains
                .iter()
                .map(|(a, b)| format!("{a}\t{b}"))
                .collect::<Vec<_>>()
                .join("\n"),
        );
        s.set_string("fontSize", self.font_size.to_string());
        s.set_string("invertPDF", self.invert.to_string());
        s.set_string("appearance", self.appearance.clone());
    }

    fn apply_theme(&self, ctx: &egui::Context) {
        ctx.set_theme(match self.appearance.as_str() {
            "light" => egui::ThemePreference::Light,
            "dark" => egui::ThemePreference::Dark,
            _ => egui::ThemePreference::System,
        });
    }
}

// MARK: - Système

/// Ouvre un fichier ou une adresse avec l'app par défaut.
fn open_with_system(target: &str) {
    #[cfg(windows)]
    let _ = std::process::Command::new("explorer").arg(target).spawn();
    #[cfg(not(windows))]
    let _ = std::process::Command::new("open").arg(target).spawn();
}

/// Montre le fichier sélectionné dans l'Explorateur.
fn reveal_in_explorer(path: &std::path::Path) {
    #[cfg(windows)]
    let _ = std::process::Command::new("explorer")
        .arg(format!("/select,{}", path.display()))
        .spawn();
    #[cfg(not(windows))]
    let _ = std::process::Command::new("open").arg("-R").arg(path).spawn();
}

fn shortcut(ctx: &egui::Context, modifiers: Modifiers, key: Key) -> bool {
    ctx.input_mut(|i| i.consume_shortcut(&KeyboardShortcut::new(modifiers, key)))
}

const CTRL: Modifiers = Modifiers::COMMAND;
const CTRL_SHIFT: Modifiers = Modifiers {
    shift: true,
    ..Modifiers::COMMAND
};
const CTRL_ALT: Modifiers = Modifiers {
    alt: true,
    ..Modifiers::COMMAND
};

// MARK: - App

struct HistoryUi {
    file: String,
    versions: Vec<Snapshot>,
    selected: Option<usize>,
    text: String,
}

struct App {
    settings: Settings,
    project: Option<Project>,
    pdf: pdf::PdfView,
    editor: Editor,
    setup: TeXSetup,
    show_log: bool,
    new_file: Option<String>, // nom en cours de saisie
    message: Option<String>,
    history: Option<HistoryUi>,
    was_focused: bool,
    title: String,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> Self {
        egui_extras::install_image_loaders(&cc.egui_ctx);
        cc.egui_ctx.options_mut(|o| o.zoom_with_keyboard = false); // Ctrl+ et Ctrl− règlent le texte de l'éditeur
        let settings = Settings::load(cc.storage);
        settings.apply_theme(&cc.egui_ctx);
        let mut app = App {
            settings,
            project: None,
            pdf: pdf::PdfView::new(&cc.egui_ctx),
            editor: Editor::default(),
            setup: tex::tex_setup(),
            show_log: false,
            new_file: None,
            message: None,
            history: None,
            was_focused: true,
            title: String::new(),
        };
        // « Ouvrir avec Nabla », ou un dossier glissé sur Nabla.exe
        if let Some(path) = std::env::args_os().nth(1) {
            app.open(PathBuf::from(path), &cc.egui_ctx);
        }
        app
    }

    fn recent_paths(&self) -> Vec<PathBuf> {
        self.settings
            .recents
            .iter()
            .map(PathBuf::from)
            .filter(|p| p.exists())
            .collect()
    }

    /// Ouvre un dossier de projet, ou le dossier d'un fichier .tex choisi (ce fichier est alors ouvert).
    fn open(&mut self, path: PathBuf, ctx: &egui::Context) {
        let is_dir = path.is_dir();
        let Some(root) = (if is_dir {
            Some(path.clone())
        } else {
            path.parent().map(PathBuf::from)
        }) else {
            return;
        };
        if !path.exists() {
            return;
        }
        let key = root.to_string_lossy().into_owned();
        self.settings.recents.retain(|r| *r != key);
        self.settings.recents.insert(0, key.clone());
        self.settings.recents.truncate(8);
        let mut p = Project::new(root.clone(), self.settings.mains.get(&key).cloned(), ctx.clone());
        if !is_dir {
            if let Some(file) = tex::relative_path(&path.to_string_lossy(), &root) {
                p.open(Some(file));
            }
        }
        self.pdf = pdf::PdfView::new(ctx);
        self.editor = Editor::default();
        self.show_log = false;
        self.project = Some(p);
    }

    fn open_dialog(&mut self, ctx: &egui::Context, folder: bool) {
        let dialog = rfd::FileDialog::new().set_title(if folder {
            "Choisir le dossier d'un projet"
        } else {
            "Choisir un fichier .tex"
        });
        let picked = if folder {
            dialog.pick_folder()
        } else {
            dialog.add_filter("LaTeX", &["tex"]).pick_file()
        };
        if let Some(path) = picked {
            self.open(path, ctx);
        }
    }

    fn new_project(&mut self, template: &tex::Template, ctx: &egui::Context) {
        let Some(path) = rfd::FileDialog::new()
            .set_title("Nouveau projet : nom du dossier à créer")
            .set_file_name("Sans titre")
            .save_file()
        else {
            return;
        };
        match tex::create_project(&path, template.main) {
            Ok(()) => self.open(path, ctx),
            Err(e) => self.message = Some(e),
        }
    }

    fn export_pdf(&mut self) {
        let Some(p) = &self.project else { return };
        let Some(data) = p.pdf.clone() else { return };
        let name = p.name() + if self.settings.invert { " (sombre).pdf" } else { ".pdf" };
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("PDF", &["pdf"])
            .set_file_name(name)
            .save_file()
        {
            self.pdf.export(data, path, self.settings.invert);
        }
    }

    fn pick_imports(&mut self) {
        if let (Some(p), Some(files)) = (
            &mut self.project,
            rfd::FileDialog::new()
                .set_title("Fichiers à copier dans le projet (images, .bib, .tex…)")
                .pick_files(),
        ) {
            p.import_files(&files);
        }
    }

    fn show_in_pdf(&mut self) {
        if let Some(p) = &self.project {
            if p.is_editing_text() {
                p.show_in_pdf(editor::line_of(&p.text, self.editor.cursor));
            }
        }
    }

    fn open_history(&mut self) {
        let Some(p) = &self.project else { return };
        let Some(file) = p.current.clone().filter(|_| p.is_editing_text()) else {
            return;
        };
        let versions = snapshots(&p.root, &file);
        let text = versions.first().map(Snapshot::text).unwrap_or_default();
        self.history = Some(HistoryUi {
            file,
            selected: (!versions.is_empty()).then_some(0),
            versions,
            text,
        });
    }

    // MARK: Raccourcis

    fn shortcuts(&mut self, ctx: &egui::Context) {
        let s = &mut self.settings;
        if shortcut(ctx, CTRL, Key::Plus) || shortcut(ctx, CTRL, Key::Equals) {
            s.font_size = (s.font_size + 1.0).min(FONT_SIZES.end);
        }
        if shortcut(ctx, CTRL, Key::Minus) {
            s.font_size = (s.font_size - 1.0).max(FONT_SIZES.start);
        }
        if shortcut(ctx, CTRL, Key::Num0) {
            s.font_size = DEFAULT_FONT_SIZE;
        }
        if shortcut(ctx, CTRL, Key::O) {
            self.open_dialog(ctx, true);
        }
        if self.project.is_none() {
            return;
        }
        if shortcut(ctx, CTRL, Key::E) {
            self.export_pdf();
        }
        if shortcut(ctx, CTRL, Key::F) {
            self.editor.open_find(false);
        }
        if shortcut(ctx, CTRL, Key::H) {
            self.editor.open_find(true);
        }
        if shortcut(ctx, CTRL, Key::J) {
            self.show_in_pdf();
        }
        if shortcut(ctx, CTRL, Key::R) || shortcut(ctx, Modifiers::NONE, Key::F5) {
            if let Some(p) = &mut self.project {
                p.compile();
            }
        }
        if shortcut(ctx, CTRL_SHIFT, Key::L) {
            self.show_log = !self.show_log;
        }
        if shortcut(ctx, CTRL_ALT, Key::I) {
            self.settings.invert = !self.settings.invert;
        }
    }

    // MARK: Menus

    fn menu_bar(&mut self, ui: &mut egui::Ui) {
        let ctx = ui.ctx().clone();
        egui::MenuBar::new().ui(ui, |ui| {
            ui.menu_button("Fichier", |ui| {
                if ui
                    .add(egui::Button::new("Ouvrir un dossier…").shortcut_text("Ctrl+O"))
                    .clicked()
                {
                    self.open_dialog(&ctx, true);
                }
                if ui.button("Ouvrir un fichier .tex…").clicked() {
                    self.open_dialog(&ctx, false);
                }
                if self.project.is_some() {
                    ui.separator();
                    if ui.button("Nouveau fichier…").clicked() {
                        self.new_file = Some(String::new());
                    }
                    if ui.button("Importer des fichiers…").clicked() {
                        self.pick_imports();
                    }
                    let can_export = self.project.as_ref().is_some_and(|p| p.pdf.is_some());
                    if ui
                        .add_enabled(can_export, egui::Button::new("Exporter en PDF…").shortcut_text("Ctrl+E"))
                        .clicked()
                    {
                        self.export_pdf();
                    }
                    ui.separator();
                    if ui.button("Revenir aux projets").clicked() {
                        self.project = None;
                    }
                }
            });
            ui.add_enabled_ui(self.project.as_ref().is_some_and(Project::is_editing_text), |ui| {
                ui.menu_button("Édition", |ui| {
                    if ui.add(egui::Button::new("Rechercher…").shortcut_text("Ctrl+F")).clicked() {
                        self.editor.open_find(false);
                    }
                    if ui
                        .add(egui::Button::new("Rechercher et remplacer…").shortcut_text("Ctrl+H"))
                        .clicked()
                    {
                        self.editor.open_find(true);
                    }
                    if let Some(p) = &self.project {
                        if ui.add(egui::Button::new("Occurrence suivante").shortcut_text("F3")).clicked() {
                            self.editor.find_next(&p.text, false);
                        }
                        if ui
                            .add(egui::Button::new("Occurrence précédente").shortcut_text("Maj+F3"))
                            .clicked()
                        {
                            self.editor.find_next(&p.text, true);
                        }
                    }
                });
            });
            ui.menu_button("Affichage", |ui| {
                ui.label(RichText::new("Apparence").weak());
                let before = self.settings.appearance.clone();
                ui.radio_value(&mut self.settings.appearance, "system".into(), "Comme le système");
                ui.radio_value(&mut self.settings.appearance, "light".into(), "Clair");
                ui.radio_value(&mut self.settings.appearance, "dark".into(), "Sombre");
                if before != self.settings.appearance {
                    self.settings.apply_theme(&ctx);
                }
                ui.separator();
                let s = &mut self.settings;
                if ui
                    .add_enabled(
                        s.font_size < FONT_SIZES.end,
                        egui::Button::new("Agrandir le texte").shortcut_text("Ctrl+="),
                    )
                    .clicked()
                {
                    s.font_size = (s.font_size + 1.0).min(FONT_SIZES.end);
                }
                if ui
                    .add_enabled(
                        s.font_size > FONT_SIZES.start,
                        egui::Button::new("Réduire le texte").shortcut_text("Ctrl+−"),
                    )
                    .clicked()
                {
                    s.font_size = (s.font_size - 1.0).max(FONT_SIZES.start);
                }
                if ui
                    .add_enabled(
                        s.font_size != DEFAULT_FONT_SIZE,
                        egui::Button::new("Taille du texte par défaut").shortcut_text("Ctrl+0"),
                    )
                    .clicked()
                {
                    s.font_size = DEFAULT_FONT_SIZE;
                }
                ui.separator();
                ui.add(egui::Checkbox::new(&mut s.invert, "Inverser les couleurs du PDF"))
                    .on_hover_text("Ctrl+Alt+I");
            });
            ui.menu_button("Aide", |ui| {
                if ui.button("À propos de Nabla").clicked() {
                    self.message = Some(format!(
                        "Nabla {} pour Windows\nÉditeur LaTeX local, sans compte ni connexion.",
                        tex::VERSION
                    ));
                }
            });
        });
    }

    // MARK: Accueil

    fn welcome(&mut self, ui: &mut egui::Ui) {
        let ctx = ui.ctx().clone();
        egui::Panel::right("recents")
            .exact_size(320.0)
            .resizable(false)
            .show(ui, |ui| {
                ui.add_space(12.0);
                ui.label(RichText::new("Récents").strong());
                ui.add_space(6.0);
                let recents = self.recent_paths();
                if recents.is_empty() {
                    ui.weak("Aucun projet pour l'instant");
                }
                for path in recents {
                    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    let parent = path.parent().map(|p| p.display().to_string()).unwrap_or_default();
                    let r = ui.add(
                        egui::Button::new(egui::Atoms::new((
                            RichText::new("📁").color(ui.visuals().selection.bg_fill),
                            RichText::new(format!("{name}\n")).strong(),
                            RichText::new(parent).small().weak(),
                        )))
                        .frame(false)
                        .min_size(vec2(ui.available_width(), 36.0)),
                    );
                    if r.clicked() {
                        self.open(path.clone(), &ctx);
                    }
                    r.context_menu(|ui| {
                        if ui.button("Afficher dans l'Explorateur").clicked() {
                            reveal_in_explorer(&path);
                        }
                        if ui.button("Retirer de la liste").clicked() {
                            // le dossier lui-même n'est pas touché
                            let key = path.to_string_lossy();
                            self.settings.recents.retain(|r| *r != key);
                        }
                    });
                }
            });
        egui::CentralPanel::default().show(ui, |ui| {
            ui.vertical_centered(|ui| {
                ui.add_space((ui.available_height() / 2.0 - 280.0).max(24.0));
                ui.add(egui::Image::new(egui::include_image!("../assets/icon.png")).fit_to_exact_size(vec2(112.0, 112.0)));
                ui.label(RichText::new("Nabla").size(30.0).strong());
                ui.weak("Vos projets LaTeX, compilés sur ce PC.");
                if self.setup != TeXSetup::Ready {
                    ui.add_space(10.0);
                    self.setup_card(ui);
                }
                ui.add_space(18.0);
                ui.label(RichText::new("Nouveau projet").strong());
                ui.add_space(6.0);
                let width = TEMPLATES.len() as f32 * 136.0;
                ui.allocate_ui_with_layout(vec2(width, 120.0), Layout::left_to_right(Align::Center), |ui| {
                    for t in TEMPLATES {
                        let card = egui::Button::new(egui::Atoms::new((
                            RichText::new(format!("{}\n", t.name)).strong(),
                            RichText::new(t.detail).small().weak(),
                        )))
                        .min_size(vec2(124.0, 96.0))
                        .corner_radius(12.0);
                        if ui
                            .add(card)
                            .on_hover_text(format!("Nouveau projet à partir du modèle « {} »", t.name))
                            .clicked()
                        {
                            self.new_project(t, &ctx);
                        }
                    }
                });
                ui.add_space(14.0);
                if ui
                    .add(egui::Button::new("📂  Ouvrir un dossier…").min_size(vec2(220.0, 32.0)))
                    .on_hover_text("Ctrl+O")
                    .clicked()
                {
                    self.open_dialog(&ctx, true);
                }
                if ui.link("ou un fichier .tex").clicked() {
                    self.open_dialog(&ctx, false);
                }
            });
        });
    }

    /// Premier lancement sans LaTeX : quoi installer, et où.
    fn setup_card(&mut self, ui: &mut egui::Ui) {
        let orange = Color32::from_rgb(255, 149, 0);
        egui::Frame::new()
            .fill(orange.gamma_multiply(0.08))
            .stroke(egui::Stroke::new(1.0, orange.gamma_multiply(0.4)))
            .corner_radius(12.0)
            .inner_margin(16.0)
            .show(ui, |ui| {
                ui.set_width(560.0);
                ui.with_layout(Layout::top_down(Align::Min), |ui| {
                    let (title, body, link) = match self.setup {
                        TeXSetup::MissingTeX => (
                            "LaTeX n'est pas installé sur ce PC",
                            "Nabla compile avec la distribution LaTeX de votre PC. Installez MiKTeX (gratuit) ou TeX Live, puis revenez ici.",
                            Some(("Télécharger MiKTeX", tex::MIKTEX_URL)),
                        ),
                        TeXSetup::MissingPerl => (
                            "Il manque Perl pour latexmk",
                            "Le latexmk de MiKTeX a besoin de Perl. Installez Strawberry Perl (gratuit), puis revenez ici.",
                            Some(("Télécharger Strawberry Perl", tex::PERL_URL)),
                        ),
                        _ => (
                            "Il manque latexmk à votre LaTeX",
                            "Ouvrez la console MiKTeX › Paquets et installez « latexmk » (TeX Live : tlmgr install latexmk).",
                            None,
                        ),
                    };
                    ui.label(RichText::new(format!("⚠  {title}")).strong());
                    ui.label(body);
                    ui.horizontal(|ui| {
                        if let Some((label, url)) = link {
                            if ui.button(label).clicked() {
                                open_with_system(url);
                            }
                        }
                        if ui.button("Vérifier de nouveau").clicked() {
                            self.setup = tex::tex_setup();
                        }
                    });
                });
            });
    }

    // MARK: Projet

    fn toolbar(&mut self, ui: &mut egui::Ui) {
        let Some(p) = &mut self.project else { return };
        let (mut back, mut export, mut history) = (false, false, false);
        ui.horizontal(|ui| {
            back = ui
                .button("‹ Projets")
                .on_hover_text("Revenir à la liste des projets")
                .clicked();
            ui.menu_button("+", |ui| {
                if ui.button("Nouveau fichier…").clicked() {
                    self.new_file = Some(String::new());
                }
                if ui.button("Importer des fichiers…").clicked() {
                    if let Some(files) = rfd::FileDialog::new()
                        .set_title("Fichiers à copier dans le projet (images, .bib, .tex…)")
                        .pick_files()
                    {
                        p.import_files(&files);
                    }
                }
            })
            .response
            .on_hover_text("Ajouter un fichier au projet (on peut aussi glisser des fichiers dans la fenêtre)");
            ui.separator();
            ui.label(RichText::new(p.name()).strong());
            ui.weak(p.status());
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let tip = if self.settings.invert {
                    "Enregistrer le PDF en sombre (couleurs inversées) — Ctrl+E"
                } else {
                    "Enregistrer le PDF où vous voulez — Ctrl+E"
                };
                export = ui
                    .add_enabled(p.pdf.is_some(), egui::Button::new("Exporter en PDF"))
                    .on_hover_text(tip)
                    .clicked();
                ui.toggle_value(&mut self.settings.invert, "◐").on_hover_text(
                    "PDF en sombre : fond noir, texte clair, couleurs gardées. L'export suit ce réglage. — Ctrl+Alt+I",
                );
                let log = if p.errors() > 0 { "⚠ Journal" } else { "☰ Journal" };
                ui.toggle_value(&mut self.show_log, log)
                    .on_hover_text("Erreurs et avertissements de la compilation — Ctrl+Maj+L");
                if ui
                    .button("⟳ Compiler")
                    .on_hover_text("Recompiler — Ctrl+R. Le PDF se met aussi à jour quand on arrête de taper.")
                    .clicked()
                {
                    p.compile();
                }
                let editing = p.is_editing_text();
                history = ui
                    .add_enabled(editing, egui::Button::new("🕓 Historique"))
                    .on_hover_text("Versions précédentes du fichier ouvert, à consulter ou restaurer")
                    .clicked();
                if ui
                    .add_enabled(editing && p.pdf.is_some(), egui::Button::new("Montrer dans le PDF"))
                    .on_hover_text("Montrer dans le PDF la ligne du curseur — Ctrl+J. Double-cliquer dans le PDF fait l'inverse.")
                    .clicked()
                {
                    p.show_in_pdf(editor::line_of(&p.text, self.editor.cursor));
                }
                if p.compiling {
                    ui.spinner();
                }
            });
        });
        if back {
            self.project = None;
        }
        if export {
            self.export_pdf();
        }
        if history {
            self.open_history();
        }
    }

    fn sidebar(&mut self, ui: &mut egui::Ui) {
        let Some(p) = &mut self.project else { return };
        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
            ui.add_space(8.0);
            ui.label(RichText::new("Fichiers").small().weak());
            let mut open = None;
            let mut main = None;
            let mut trash = None;
            for file in &p.files {
                let is_main = p.main.as_deref() == Some(file.as_str());
                let icon = match ext(file).as_str() {
                    "tex" => "📄",
                    "bib" => "📚",
                    "pdf" => "📕",
                    "png" | "jpg" | "jpeg" | "gif" | "tif" | "tiff" | "svg" | "eps" => "🖼",
                    _ => "🗋",
                };
                let mut label = RichText::new(format!("{icon} {file}"));
                if is_main {
                    label = label.color(ui.visuals().selection.bg_fill);
                }
                let selected = p.current.as_deref() == Some(file.as_str());
                let r = ui.add(
                    egui::Button::selectable(selected, label)
                        .min_size(vec2(ui.available_width(), 0.0))
                        .right_text(if is_main {
                            RichText::new("principal").small().weak()
                        } else {
                            RichText::new("")
                        }),
                );
                if r.clicked() && !selected {
                    open = Some(file.clone());
                }
                r.context_menu(|ui| {
                    if ext(file) == "tex"
                        && ui
                            .add_enabled(!is_main, egui::Button::new("Définir comme document principal"))
                            .clicked()
                    {
                        main = Some(file.clone());
                    }
                    if ui.button("Afficher dans l'Explorateur").clicked() {
                        reveal_in_explorer(&p.path(file));
                    }
                    ui.separator();
                    if ui.button("Placer dans la corbeille").clicked() {
                        trash = Some(file.clone());
                    }
                });
            }
            if let Some(f) = open {
                p.open(Some(f));
            }
            if let Some(f) = main {
                self.settings.mains.insert(p.root.to_string_lossy().into_owned(), f.clone());
                p.set_main(Some(f));
            }
            if let Some(f) = trash {
                p.trash(&f);
            }
            if !p.outline.is_empty() {
                ui.add_space(14.0);
                ui.label(RichText::new("Plan").small().weak());
                let top = p.outline.iter().map(|i| i.level).min().unwrap_or(0);
                let mut reveal = None;
                for item in &p.outline {
                    ui.horizontal(|ui| {
                        ui.add_space((item.level - top) as f32 * 12.0);
                        let text = if item.level == top {
                            RichText::new(&item.title).strong()
                        } else {
                            RichText::new(&item.title).weak()
                        };
                        let r = ui.add(egui::Button::new(text).frame(false).truncate());
                        if r.on_hover_text(format!("{}, ligne {}", item.file, item.line)).clicked() {
                            reveal = Some((item.file.clone(), item.line));
                        }
                    });
                }
                if let Some((f, l)) = reveal {
                    p.reveal(Some(&f), Some(l));
                }
            }
        });
    }

    fn preview(&mut self, ui: &mut egui::Ui) {
        let Some(p) = &mut self.project else { return };
        let mut reveal = None;
        if self.show_log {
            egui::Panel::bottom("log").exact_size(230.0).show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Journal").strong());
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui.small_button("✕").on_hover_text("Fermer le journal").clicked() {
                            self.show_log = false;
                        }
                        if let Some(raw) = p.output(".log").filter(|r| r.exists()) {
                            if ui.button("Journal complet").clicked() {
                                open_with_system(&raw.to_string_lossy());
                            }
                        }
                    });
                });
                ui.separator();
                if p.log.is_empty() {
                    ui.weak("✓ Aucune erreur ni avertissement");
                }
                egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                    for item in &p.log {
                        let (icon, color) = match item.kind {
                            Kind::Error => ("⛔", Color32::from_rgb(255, 59, 48)),
                            Kind::Warning => ("⚠", Color32::from_rgb(255, 149, 0)),
                        };
                        let place = match (&item.file, item.line) {
                            (Some(f), Some(l)) => format!("{f}:{l}"),
                            (None, Some(l)) => format!("ligne {l}"),
                            _ => String::new(),
                        };
                        let r = ui.horizontal(|ui| {
                            ui.label(RichText::new(icon).color(color));
                            ui.add(egui::Label::new(&item.message).wrap());
                            ui.with_layout(Layout::right_to_left(Align::Min), |ui| {
                                ui.weak(RichText::new(place).monospace().small())
                            });
                        });
                        let r = r.response.interact(egui::Sense::click());
                        if item.file.is_some() && r.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                            reveal = Some((item.file.clone(), item.line));
                        }
                    }
                });
            });
        } else if let Some(first) = p.log.iter().find(|i| i.kind == Kind::Error).cloned() {
            let count = p.errors();
            egui::Panel::bottom("error").show(ui, |ui| {
                ui.add_space(4.0);
                ui.horizontal(|ui| {
                    ui.label(RichText::new("⛔").color(Color32::from_rgb(255, 59, 48)));
                    ui.add(egui::Label::new(RichText::new(&first.message).strong()).wrap());
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui
                            .button(if count > 1 {
                                format!("Journal ({count})")
                            } else {
                                "Journal".into()
                            })
                            .clicked()
                        {
                            self.show_log = true;
                        }
                        if let (Some(f), Some(l)) = (&first.file, first.line) {
                            if ui.link(format!("{f} : ligne {l}")).clicked() {
                                reveal = Some((first.file.clone(), first.line));
                            }
                        }
                    });
                });
                ui.add_space(4.0);
            });
        }
        if let Some((f, l)) = reveal {
            p.reveal(f.as_deref(), l);
        }
        let bg = if self.settings.invert {
            Color32::from_gray(38)
        } else if ui.visuals().dark_mode {
            Color32::from_gray(30)
        } else {
            Color32::from_gray(222)
        };
        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(bg))
            .show(ui, |ui| {
                if let Some(e) = &self.pdf.error {
                    centered_message(ui, "PDF indisponible", e);
                } else if p.pdf.is_none() || !self.pdf.has_document() {
                    let title = if p.compiling { "Compilation…" } else { "Pas encore de PDF" };
                    centered_message(ui, title, "Le PDF s'affiche ici dès que le document principal compile.");
                }
                self.pdf.show(ui, p, self.settings.invert);
            });
    }

    fn editor_pane(&mut self, ui: &mut egui::Ui) {
        let Some(p) = &mut self.project else { return };
        if p.is_editing_text() {
            self.editor.show(ui, p, self.settings.font_size);
        } else if let Some(current) = p
            .current
            .clone()
            .filter(|c| ["png", "jpg", "jpeg", "gif"].contains(&ext(c).as_str()))
        {
            let uri = format!("file://{}", p.path(&current).display());
            ui.centered_and_justified(|ui| ui.add(egui::Image::new(uri).shrink_to_fit()));
        } else {
            let (title, body) = match &p.current {
                None => ("Aucun fichier ouvert", "Choisissez un fichier dans la liste.".to_string()),
                Some(_) => (
                    "Aperçu indisponible",
                    p.open_error
                        .clone()
                        .unwrap_or("Ce type de fichier ne se modifie pas ici.".into()),
                ),
            };
            centered_message(ui, title, &body);
        }
    }

    fn dialogs(&mut self, ctx: &egui::Context) {
        if let Some(name) = &mut self.new_file {
            let mut done = None;
            egui::Modal::new(egui::Id::unique("new-file")).show(ctx, |ui| {
                ui.set_width(380.0);
                ui.label(RichText::new("Nouveau fichier").strong());
                ui.label(
                    "Nom du fichier, éventuellement dans un sous-dossier (chap/intro.tex). Sans extension, ce sera un .tex.",
                );
                let r = ui.add(
                    egui::TextEdit::singleline(name)
                        .hint_text("chapitre.tex")
                        .desired_width(f32::INFINITY),
                );
                r.request_focus();
                let enter = r.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
                ui.horizontal(|ui| {
                    if ui.button("Créer").clicked() || enter {
                        done = Some(true);
                    }
                    if ui.button("Annuler").clicked() || ui.input(|i| i.key_pressed(Key::Escape)) {
                        done = Some(false);
                    }
                });
            });
            if let Some(create) = done {
                let name = self.new_file.take().unwrap_or_default();
                if create {
                    if let Some(p) = &mut self.project {
                        self.message = p.create_file(&name).err();
                    }
                }
            }
        }
        if let Some(message) = self.message.clone() {
            let r = egui::Modal::new(egui::Id::unique("message")).show(ctx, |ui| {
                ui.set_max_width(420.0);
                ui.label(message);
                ui.button("OK").clicked()
            });
            if r.inner || r.should_close() {
                self.message = None;
            }
        }
        if let Some(Err(e)) = self.pdf.export_result.take() {
            self.message = Some(format!("Export impossible : {e}"));
        }
        self.history_dialog(ctx);
    }

    fn history_dialog(&mut self, ctx: &egui::Context) {
        let Some(h) = &mut self.history else { return };
        let mut close = false;
        let mut restore = None;
        let r = egui::Modal::new(egui::Id::unique("history")).show(ctx, |ui| {
            ui.set_width(780.0);
            ui.set_height(520.0);
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("Historique de {}", h.file)).strong());
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    close = ui.button("Fermer").clicked()
                });
            });
            ui.separator();
            if h.versions.is_empty() {
                centered_message(
                    ui,
                    "Aucune version enregistrée",
                    "Une version est gardée à l'ouverture du fichier, puis toutes les deux minutes de travail.",
                );
                return;
            }
            ui.horizontal_top(|ui| {
                ui.vertical(|ui| {
                    ui.set_width(230.0);
                    egui::ScrollArea::vertical()
                        .id_salt("versions")
                        .max_height(430.0)
                        .show(ui, |ui| {
                            for (i, v) in h.versions.iter().enumerate() {
                                let label = format!("{}\n{}", relative_date(v.date), absolute_date(v.date));
                                if ui
                                    .add(egui::Button::selectable(h.selected == Some(i), label).min_size(vec2(220.0, 0.0)))
                                    .clicked()
                                {
                                    h.selected = Some(i);
                                    h.text = v.text();
                                }
                            }
                        });
                });
                ui.separator();
                egui::ScrollArea::both()
                    .id_salt("version-text")
                    .max_height(430.0)
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        ui.add(egui::Label::new(RichText::new(&h.text).monospace()).selectable(true).extend());
                    });
            });
            ui.separator();
            ui.horizontal(|ui| {
                ui.weak("Restaurer garde aussi la version actuelle dans l'historique.");
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if ui
                        .add_enabled(h.selected.is_some(), egui::Button::new("Restaurer cette version"))
                        .clicked()
                    {
                        restore = h.selected.map(|i| h.versions[i].clone());
                    }
                });
            });
        });
        if let (Some(s), Some(p)) = (&restore, &mut self.project) {
            p.restore(s);
        }
        if close || restore.is_some() || r.should_close() {
            self.history = None;
        }
    }
}

fn centered_message(ui: &mut egui::Ui, title: &str, body: &str) {
    ui.vertical_centered(|ui| {
        ui.add_space(ui.available_height() / 2.0 - 30.0);
        ui.label(RichText::new(title).size(17.0).strong());
        ui.weak(body);
    });
}

fn relative_date(date: std::time::SystemTime) -> String {
    let s = date.elapsed().unwrap_or_default().as_secs();
    match s {
        0..60 => "à l'instant".into(),
        60..3600 => format!("il y a {} min", s / 60),
        3600..86400 => format!("il y a {} h", s / 3600),
        86400..172800 => "hier".into(),
        _ => format!("il y a {} jours", s / 86400),
    }
}

fn absolute_date(date: std::time::SystemTime) -> String {
    chrono::DateTime::<chrono::Local>::from(date)
        .format("%d/%m/%Y à %H:%M:%S")
        .to_string()
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let focused = ctx.input(|i| i.focused);
        if focused && !self.was_focused {
            // Au retour dans l'app, par exemple après avoir installé MiKTeX ou modifié un fichier ailleurs.
            self.setup = tex::tex_setup();
            if let Some(p) = &mut self.project {
                p.reload();
            }
        }
        self.was_focused = focused;
        self.shortcuts(&ctx);

        let dropped: Vec<PathBuf> = ctx.input(|i| i.raw.dropped_files.iter().map(|f| f.path().to_path_buf()).collect());
        if !dropped.is_empty() {
            match &mut self.project {
                Some(p) => p.import_files(&dropped),
                None => self.open(dropped[0].clone(), &ctx),
            }
        }

        if let Some(p) = &mut self.project {
            p.poll(focused);
            if let Some(main) = &p.main {
                self.settings
                    .mains
                    .insert(p.root.to_string_lossy().into_owned(), main.clone());
            }
        }
        let title = self
            .project
            .as_ref()
            .map_or("Nabla".into(), |p| format!("{} — Nabla", p.name()));
        if title != self.title {
            ctx.send_viewport_cmd(egui::ViewportCommand::Title(title.clone()));
            self.title = title;
        }

        egui::Panel::top("menu").show(ui, |ui| self.menu_bar(ui));
        if self.project.is_none() {
            self.welcome(ui);
        } else {
            egui::Panel::top("toolbar").show(ui, |ui| {
                ui.add_space(4.0);
                self.toolbar(ui);
                ui.add_space(2.0);
            });
            if self.project.is_some() {
                egui::Panel::left("files")
                    .default_size(240.0)
                    .size_range(220.0..=360.0)
                    .show(ui, |ui| self.sidebar(ui));
                let half = (ui.available_width() / 2.0).max(320.0);
                egui::Panel::right("preview")
                    .default_size(half)
                    .size_range(320.0..=f32::INFINITY)
                    .frame(egui::Frame::NONE)
                    .show(ui, |ui| self.preview(ui));
                let editor_bg = ui.visuals().extreme_bg_color;
                egui::CentralPanel::default()
                    .frame(egui::Frame::new().fill(editor_bg))
                    .show(ui, |ui| self.editor_pane(ui));
            }
        }
        self.dialogs(&ctx);
    }

    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        self.settings.save(storage);
    }
}
