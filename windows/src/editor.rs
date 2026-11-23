// Éditeur LaTeX : coloration (recalculée seulement quand le texte change), numéros de ligne, complétion,
// recherche et remplacement. Pendant de Editor.swift et de la partie éditeur de Completion.swift.
use crate::completion::{CompletionKind, Context, Sources, accept, byte_index, completion_context, suggestions};
use crate::project::Project;
use egui::{
    Align, Color32, Event, FontId, Id, Key, Modifiers, TextEdit, TextFormat, pos2, text::CCursor, text::CCursorRange,
    text::LayoutJob, vec2,
};
use regex::{Regex, RegexBuilder};
use std::{ops::Range, sync::Arc};

pub const DEFAULT_FONT_SIZE: f32 = 13.5;
pub const FONT_SIZES: Range<f32> = 10.0..24.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tok {
    Normal,
    Brace,
    Command,
    Environment,
    Math,
    Comment,
}

/// Coloration d'une ligne, en plages d'octets contiguës. Mêmes règles que l'app Mac, par ordre de priorité :
/// commentaire (« % » précédé d'un nombre pair de « \ »), délimiteurs de maths, \begin{…} et \end{…},
/// commandes, accolades et crochets.
pub fn tokens(text: &str) -> Vec<(Range<usize>, Tok)> {
    let b = text.as_bytes();
    let mut out: Vec<(Range<usize>, Tok)> = Vec::new();
    let mut push = |r: Range<usize>, t: Tok| match out.last_mut() {
        Some((last, lt)) if *lt == t && last.end == r.start => last.end = r.end,
        _ => out.push((r, t)),
    };
    let mut line_start = 0;
    while line_start <= b.len() {
        let line_end = text[line_start..].find('\n').map_or(b.len(), |i| line_start + i);
        let mut comment = line_end;
        let mut slashes = 0;
        for i in line_start..line_end {
            match b[i] {
                b'\\' => slashes += 1,
                b'%' if slashes % 2 == 0 => {
                    comment = i;
                    break;
                }
                _ => slashes = 0,
            }
        }
        let mut i = line_start;
        while i < comment {
            let (len, tok) = match b[i] {
                b'\\' if i + 1 < comment && (b[i + 1].is_ascii_alphabetic() || b[i + 1] == b'@') => {
                    let mut j = i + 1;
                    while j < comment && (b[j].is_ascii_alphabetic() || b[j] == b'@') {
                        j += 1;
                    }
                    let name = &text[i + 1..j];
                    if j < comment && b[j] == b'*' {
                        j += 1;
                    }
                    match text[j..comment].strip_prefix('{').and_then(|r| r.find('}')) {
                        Some(close) if name == "begin" || name == "end" => (j + 1 + close + 1 - i, Tok::Environment),
                        _ => (j - i, Tok::Command),
                    }
                }
                b'\\' if i + 1 < comment => {
                    let c = text[i + 1..].chars().next().unwrap();
                    (1 + c.len_utf8(), if "[]()".contains(c) { Tok::Math } else { Tok::Command })
                }
                b'$' => (if i + 1 < comment && b[i + 1] == b'$' { 2 } else { 1 }, Tok::Math),
                b'{' | b'}' | b'[' | b']' => (1, Tok::Brace),
                _ => (1, Tok::Normal),
            };
            push(i..i + len, tok);
            i += len;
        }
        if comment < line_end {
            push(comment..line_end, Tok::Comment);
        }
        if line_end < b.len() {
            push(line_end..line_end + 1, Tok::Normal);
        }
        line_start = line_end + 1;
    }
    out
}

/// Couleurs des couleurs système du Mac, en clair et en sombre.
fn color(tok: Tok, dark: bool, text: Color32) -> Color32 {
    let pick = |l: [u8; 3], d: [u8; 3]| {
        let c = if dark { d } else { l };
        Color32::from_rgb(c[0], c[1], c[2])
    };
    match tok {
        Tok::Normal => text,
        Tok::Brace | Tok::Comment => pick([110, 110, 115], [152, 152, 157]),
        Tok::Command => pick([0, 122, 255], [10, 132, 255]),
        Tok::Environment => pick([175, 82, 222], [191, 90, 242]),
        Tok::Math => pick([255, 149, 0], [255, 159, 10]),
    }
}

/// Texte coloré, avec les occurrences recherchées surlignées.
pub fn layout_job(text: &str, size: f32, dark: bool, fg: Color32, matches: &[Range<usize>]) -> LayoutJob {
    let mut job = LayoutJob {
        text: text.to_string(),
        ..Default::default()
    };
    let base = TextFormat {
        font_id: FontId::monospace(size),
        line_height: Some((size * 1.5).round()),
        ..Default::default()
    };
    let found = if dark {
        Color32::from_rgba_unmultiplied(255, 214, 10, 70)
    } else {
        Color32::from_rgba_unmultiplied(255, 214, 10, 110)
    };
    let mut m = matches.iter().peekable();
    for (range, tok) in tokens(text) {
        let mut at = range.start;
        while at < range.end {
            while m.peek().is_some_and(|r| r.end <= at) {
                m.next();
            }
            let (end, hit) = match m.peek() {
                Some(r) if r.start <= at => (r.end.min(range.end), true),
                Some(r) => (r.start.min(range.end), false),
                None => (range.end, false),
            };
            job.sections.push(egui::text::LayoutSection {
                leading_space: 0.0,
                byte_range: egui::text::ByteIndex(at)..egui::text::ByteIndex(end),
                format: TextFormat {
                    color: color(tok, dark, fg),
                    italics: tok == Tok::Comment, // la couleur seule ne suffit pas à distinguer les commentaires
                    background: if hit { found } else { Color32::TRANSPARENT },
                    ..base.clone()
                },
            });
            at = end;
        }
    }
    if job.sections.is_empty() {
        job.sections.push(egui::text::LayoutSection {
            leading_space: 0.0,
            byte_range: egui::text::ByteIndex(0)..egui::text::ByteIndex(0),
            format: base,
        });
    }
    job
}

/// Premier caractère de la ligne `line` (à partir de 1), et le caractère qui suit sa fin.
pub fn line_chars(text: &str, line: usize) -> Range<usize> {
    let mut start = 0;
    let mut n = 1;
    for (i, c) in text.chars().enumerate() {
        if n == line {
            start = i;
            break;
        }
        if c == '\n' {
            n += 1;
            start = i + 1;
        }
    }
    let len = text.chars().skip(start).take_while(|c| *c != '\n').count();
    start..start + len + 1
}

pub fn line_of(text: &str, cursor: usize) -> usize {
    text[..byte_index(text, cursor)].matches('\n').count() + 1
}

type Params = (u32, bool, Color32, Option<String>, u32, u32);

#[derive(Default)]
pub struct Find {
    pub open: bool,
    pub replace: bool,
    pub query: String,
    pub replacement: String,
    focus: bool,
}

struct Popup {
    ctx: Context,
    items: Vec<String>,
    selected: usize,
    sources: Option<Sources>,
}

#[derive(Default)]
pub struct Editor {
    cache: Option<(String, Params, Arc<egui::Galley>)>, // dernière mise en page : réutilisée tant que rien ne change
    pub find: Find,
    popup: Option<Popup>,
    reopen: bool,
    pub cursor: usize,
    selection: Range<usize>,      // sélection affichée, en caractères
    select: Option<Range<usize>>, // sélection à appliquer à la prochaine image
    popup_rect: Option<egui::Rect>,
}

impl Editor {
    pub fn open_find(&mut self, replace: bool) {
        self.find.open = true;
        self.find.replace |= replace;
        self.find.focus = true;
    }

    fn regex(&self) -> Option<Regex> {
        (self.find.open && !self.find.query.is_empty())
            .then(|| {
                RegexBuilder::new(&regex::escape(&self.find.query))
                    .case_insensitive(true)
                    .build()
                    .ok()
            })
            .flatten()
    }

    /// Occurrence suivante (ou précédente) à partir du curseur, sélectionnée et montrée.
    pub fn find_next(&mut self, text: &str, backwards: bool) {
        let Some(re) = self.regex() else { return };
        let at = byte_index(text, self.cursor);
        let all: Vec<Range<usize>> = re.find_iter(text).map(|m| m.range()).collect();
        let hit = if backwards {
            let before = byte_index(text, self.selection.start);
            all.iter().rev().find(|r| r.end <= before).or(all.last())
        } else {
            all.iter().find(|r| r.start >= at).or(all.first())
        };
        if let Some(r) = hit {
            let start = text[..r.start].chars().count();
            self.select = Some(start..start + text[r.clone()].chars().count());
        }
    }

    pub fn show(&mut self, ui: &mut egui::Ui, project: &mut Project, size: f32) {
        let file = project.current.clone().unwrap_or_default();
        let id = Id::unique(("editor", &file, project.load_gen));
        let mut changed_by_us = false;

        // Barre de recherche (Ctrl+F) et de remplacement (Ctrl+H).
        if self.find.open {
            let mut close = false;
            egui::Frame::new()
                .inner_margin(egui::Margin::symmetric(10, 6))
                .fill(ui.visuals().panel_fill)
                .show(ui, |ui| {
                    ui.horizontal(|ui| {
                        let r = ui.add(
                            TextEdit::singleline(&mut self.find.query)
                                .hint_text("Rechercher")
                                .desired_width(220.0),
                        );
                        if std::mem::take(&mut self.find.focus) {
                            r.request_focus();
                        }
                        if r.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter)) {
                            self.find_next(&project.text, ui.input(|i| i.modifiers.shift));
                            r.request_focus();
                        }
                        let count = self.regex().map_or(0, |re| re.find_iter(&project.text).count());
                        if !self.find.query.is_empty() {
                            ui.weak(match count {
                                0 => "Aucune occurrence".to_string(),
                                1 => "1 occurrence".to_string(),
                                n => format!("{n} occurrences"),
                            });
                        }
                        if ui.small_button("‹").on_hover_text("Occurrence précédente — Maj+F3").clicked() {
                            self.find_next(&project.text, true);
                        }
                        if ui.small_button("›").on_hover_text("Occurrence suivante — F3").clicked() {
                            self.find_next(&project.text, false);
                        }
                        ui.toggle_value(&mut self.find.replace, "Remplacer");
                        if ui.small_button("✕").on_hover_text("Fermer — Échap").clicked() {
                            close = true;
                        }
                    });
                    if self.find.replace {
                        ui.horizontal(|ui| {
                            ui.add(
                                TextEdit::singleline(&mut self.find.replacement)
                                    .hint_text("Remplacer par")
                                    .desired_width(220.0),
                            );
                            let re = self.regex();
                            if ui.add_enabled(re.is_some(), egui::Button::new("Remplacer")).clicked() {
                                // l'occurrence sélectionnée, puis la suivante
                                if let Some(re) = &re {
                                    let sel = self.selection.clone();
                                    let (a, b) = (byte_index(&project.text, sel.start), byte_index(&project.text, sel.end));
                                    if re.find(&project.text[a..b]).is_some_and(|m| m.range() == (0..b - a)) {
                                        project.text.replace_range(a..b, &self.find.replacement);
                                        self.cursor = sel.start + self.find.replacement.chars().count();
                                        changed_by_us = true;
                                    }
                                }
                                self.find_next(&project.text, false);
                            }
                            if ui.add_enabled(re.is_some(), egui::Button::new("Tout remplacer")).clicked() {
                                if let Some(re) = &re {
                                    let new = re
                                        .replace_all(&project.text, regex::NoExpand(&self.find.replacement))
                                        .into_owned();
                                    if new != project.text {
                                        project.text = new;
                                        changed_by_us = true;
                                    }
                                }
                            }
                        });
                    }
                });
            if close || ui.input(|i| i.key_pressed(Key::Escape)) && self.popup.is_none() {
                self.find.open = false;
                ui.memory_mut(|m| m.request_focus(id));
            }
            ui.separator();
        }
        if ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::F3) || i.consume_key(Modifiers::COMMAND, Key::G)) {
            self.find_next(&project.text, false);
        }
        if ui.input_mut(|i| {
            i.consume_key(Modifiers::SHIFT, Key::F3) || i.consume_key(Modifiers::COMMAND | Modifiers::SHIFT, Key::G)
        }) {
            self.find_next(&project.text, true);
        }

        // Ligne demandée (plan, journal, SyncTeX) : sélectionnée et montrée.
        if let Some(line) = project.pending_line.take() {
            let r = line_chars(&project.text, line);
            self.select = Some(r.start..r.end.min(project.text.chars().count()));
        }
        let selecting = self.select.take();
        if let Some(sel) = &selecting {
            let mut state = TextEdit::load_state(ui.ctx(), id).unwrap_or_default();
            state
                .cursor
                .set_char_range(Some(CCursorRange::two(CCursor::new(sel.start), CCursor::new(sel.end))));
            TextEdit::store_state(ui.ctx(), id, state);
            ui.memory_mut(|m| m.request_focus(id));
            self.cursor = sel.end;
        }

        // Touches de la liste de complétion, prises avant l'éditeur.
        let (mut down, mut up, mut accept_key, mut dismiss) = (0, 0, false, false);
        if self.popup.is_some() {
            ui.input_mut(|i| {
                down = i.count_and_consume_key(Modifiers::NONE, Key::ArrowDown);
                up = i.count_and_consume_key(Modifiers::NONE, Key::ArrowUp);
                accept_key = i.consume_key(Modifiers::NONE, Key::Enter) || i.consume_key(Modifiers::NONE, Key::Tab);
                dismiss = i.consume_key(Modifiers::NONE, Key::Escape);
            });
        }
        let typed: Option<char> = ui.input(|i| {
            let texts: Vec<&String> = i
                .events
                .iter()
                .filter_map(|e| if let Event::Text(t) = e { Some(t) } else { None })
                .collect();
            match texts.as_slice() {
                [t] if t.chars().count() == 1 => t.chars().next(),
                _ => None,
            }
        });

        let dark = ui.visuals().dark_mode;
        let fg = ui.visuals().text_color();
        let query = self.regex();
        let cache = &mut self.cache;
        let mut layouter = |ui: &egui::Ui, buf: &dyn egui::TextBuffer, wrap: f32| {
            let text = buf.as_str();
            let params = (
                size.to_bits(),
                dark,
                fg,
                query.as_ref().map(|q| q.as_str().to_string()),
                wrap.to_bits(),
                ui.pixels_per_point().to_bits(),
            );
            // Image sans frappe (curseur qui clignote, défilement) : rien à recalculer.
            if let Some((t, p, galley)) = cache.as_ref().filter(|(t, p, _)| *p == params && t == text) {
                let _ = (t, p);
                return galley.clone();
            }
            // shortcut: au-delà de 5000 occurrences, la recherche ne surligne plus (le texte reste rapide)
            let matches: Vec<Range<usize>> = query
                .as_ref()
                .map(|re| re.find_iter(text).take(5000).map(|m| m.range()).collect())
                .unwrap_or_default();
            let mut job = layout_job(text, size, dark, fg, &matches);
            job.wrap.max_width = wrap;
            let galley = ui.fonts_mut(|f| f.layout_job(job));
            *cache = Some((text.to_string(), params, galley.clone()));
            galley
        };

        let lines = project.text.bytes().filter(|b| *b == b'\n').count() + 1;
        let digits = (lines.ilog10() + 1).max(2) as f32;
        let gutter = digits * (size * 0.8).max(10.0) * 0.62 + 18.0;
        // Un clic dans la liste de complétion ne doit pas ôter le curseur à l'éditeur.
        let over_popup = self.popup.is_some()
            && self
                .popup_rect
                .zip(ui.input(|i| i.pointer.hover_pos()))
                .is_some_and(|(r, p)| r.contains(p));
        let surrender = ui.ctx().options(|o| o.input_options.surrender_focus_on);
        if over_popup {
            ui.ctx()
                .options_mut(|o| o.input_options.surrender_focus_on = egui::SurrenderFocusOn::Never);
        }
        // Le défilement dépend du fichier seulement : un fichier relu du disque garde sa position.
        let scroll = egui::ScrollArea::vertical()
            .id_salt(("scroll", &file))
            .auto_shrink([false, false]);
        scroll.show(ui, |ui| {
            ui.horizontal_top(|ui| {
                let gutter_x = ui.cursor().min.x;
                ui.add_space(gutter);
                let output = TextEdit::multiline(&mut project.text)
                    .id(id)
                    .code_editor()
                    .frame(egui::Frame::NONE)
                    .margin(vec2(8.0, 18.0))
                    .desired_width(f32::INFINITY)
                    .layouter(&mut layouter)
                    .show(ui);
                ui.ctx().options_mut(|o| o.input_options.surrender_focus_on = surrender);
                let response = &output.response.response;
                if response.changed() {
                    changed_by_us = true;
                }
                if let Some(c) = output.cursor_range {
                    self.cursor = c.primary.index.0;
                    let (a, b) = (c.primary.index.0, c.secondary.index.0);
                    self.selection = a.min(b)..a.max(b);
                }
                let galley = &output.galley;
                let at = |char: usize| {
                    galley
                        .pos_from_cursor(CCursor::new(char))
                        .translate(output.galley_pos.to_vec2())
                };
                if let Some(sel) = &selecting {
                    ui.scroll_to_rect(at(sel.start), Some(Align::Center));
                }

                // Numéros de ligne : un par ligne du fichier (une ligne coupée à l'affichage garde un seul numéro),
                // celui de la ligne du curseur plus visible.
                let clip = ui.clip_rect();
                let painter = ui.painter();
                let font = FontId::monospace((size * 0.8).max(10.0));
                let (weak, strong) = (ui.visuals().weak_text_color(), ui.visuals().strong_text_color());
                let cursor_line = line_of(&project.text, self.cursor);
                let (mut line, mut new_line) = (1, true);
                let row_height = galley.rows.first().map_or(size, |r| r.rect().height());
                for row in &galley.rows {
                    let y = output.galley_pos.y + row.pos.y;
                    if new_line && y + row_height >= clip.top() && y <= clip.bottom() {
                        let current = line == cursor_line;
                        painter.text(
                            pos2(gutter_x + gutter - 6.0, y + row_height / 2.0),
                            egui::Align2::RIGHT_CENTER,
                            line.to_string(),
                            font.clone(),
                            if current { strong } else { weak },
                        );
                    }
                    if row.ends_with_newline {
                        line += 1;
                        new_line = true;
                    } else {
                        new_line = false;
                    }
                    if y > clip.bottom() {
                        break;
                    }
                }

                // Complétion : ouverte par la frappe d'une lettre après « \ », ou dans \ref{, \cite{, \begin{.
                let has_focus = response.has_focus();
                let reopen = std::mem::take(&mut self.reopen);
                if changed_by_us || reopen {
                    let ctx = completion_context(&project.text, self.cursor);
                    let wanted = self.popup.is_some()
                        || reopen
                        || matches!((&ctx, typed), (Some(c), Some(t))
                            if if c.kind == CompletionKind::Command { t.is_alphabetic() } else { !" }".contains(t) });
                    match ctx.filter(|_| wanted && has_focus) {
                        Some(ctx) => {
                            let mut sources = self.popup.take().and_then(|p| p.sources);
                            if ctx.kind != CompletionKind::Command && sources.is_none() {
                                sources = Some(project.sources()); // lus une fois par ouverture de la liste
                            }
                            let typed_word: String = project.text.chars().skip(ctx.range.start).take(ctx.range.len()).collect();
                            let items = suggestions(
                                &ctx,
                                &typed_word,
                                &project.text,
                                sources.as_ref().unwrap_or(&Sources::default()),
                            );
                            self.popup = (!items.is_empty()).then_some(Popup {
                                ctx,
                                items,
                                selected: 0,
                                sources,
                            });
                        }
                        None => self.popup = None,
                    }
                } else if self.popup.as_ref().is_some_and(|p| self.cursor != p.ctx.range.end) {
                    self.popup = None; // curseur déplacé ailleurs (clic, flèches gauche et droite)
                }
                if dismiss || !has_focus {
                    self.popup = None;
                }
                let mut chosen = None;
                if let Some(popup) = &mut self.popup {
                    let len = popup.items.len();
                    popup.selected = (popup.selected + down + len - up % len) % len;
                    if accept_key {
                        chosen = Some(popup.selected);
                    }
                    let anchor = at(popup.ctx.range.start);
                    let area = egui::Area::new(id.with("completion"))
                        .order(egui::Order::Foreground)
                        .fixed_pos(pos2(anchor.left() - 4.0, anchor.bottom() + 2.0))
                        .show(ui.ctx(), |ui| {
                            egui::Frame::popup(ui.style()).show(ui, |ui| {
                                ui.set_min_width(180.0);
                                egui::ScrollArea::vertical().max_height(220.0).show(ui, |ui| {
                                    for (i, item) in popup.items.iter().enumerate() {
                                        let label = egui::RichText::new(item).monospace();
                                        let r = ui.add(
                                            egui::Button::selectable(i == popup.selected, label)
                                                .min_size(vec2(ui.available_width(), 0.0)),
                                        );
                                        if i == popup.selected && down + up > 0 {
                                            r.scroll_to_me(None);
                                        }
                                        if r.clicked() {
                                            chosen = Some(i);
                                        }
                                    }
                                });
                            });
                        });
                    self.popup_rect = Some(area.response.rect);
                }
                if let Some(i) = chosen {
                    let popup = self.popup.take().unwrap();
                    let (text, cursor, chain) = accept(&project.text, &popup.ctx, &popup.items[i]);
                    project.text = text;
                    self.cursor = cursor;
                    let mut state = TextEdit::load_state(ui.ctx(), id).unwrap_or_default();
                    state.cursor.set_char_range(Some(CCursorRange::one(CCursor::new(cursor))));
                    TextEdit::store_state(ui.ctx(), id, state);
                    ui.memory_mut(|m| m.request_focus(id));
                    changed_by_us = true;
                    self.reopen = chain; // \begin{, \ref{, \cite{ : enchaîne sur le nom de l'environnement, du label…
                    ui.ctx().request_repaint();
                }
            });
        });
        if changed_by_us {
            project.edited();
        }
    }
}
