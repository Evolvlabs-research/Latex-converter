// PDF : rendu par PDFium dans un fil à part (l'éditeur ne gèle jamais), affichage, PDF en sombre et export.
// Pendant de la partie PDF de ProjectView.swift.
use crate::project::Project;
use egui::{Color32, ColorImage, Rect, Sense, TextureHandle, TextureOptions, pos2, vec2};
use pdfium_render::prelude::*;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, mpsc},
    thread,
    time::Instant,
};

/// Clarté inversée, teintes gardées (un encadré bleu reste bleu) : y = 1 − 0,89·x donne un fond #1C1C1C
/// plutôt qu'un noir pur, et un texte blanc. Même réglage que l'app Mac.
pub const INVERT_BLACK_LEVEL: f32 = 0.89;

/// Inverse la luminance (Y de YIQ) et garde la teinte (I et Q), comme l'inversion suivie d'une rotation de 180°.
pub fn invert_rgba(pixels: &mut [u8]) {
    let k = INVERT_BLACK_LEVEL;
    for p in pixels.chunks_exact_mut(4) {
        let (r, g, b) = (p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0);
        let y = 1.0 - k * (0.299 * r + 0.587 * g + 0.114 * b);
        let i = k * (0.596 * r - 0.274 * g - 0.322 * b);
        let q = k * (0.211 * r - 0.523 * g + 0.312 * b);
        let to = |v: f32| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
        p[0] = to(y + 0.956 * i + 0.621 * q);
        p[1] = to(y - 0.272 * i - 0.647 * q);
        p[2] = to(y - 1.106 * i + 1.703 * q);
    }
}

/// PDFium : à côté de Nabla.exe (pdfium.dll), sinon dans windows/pdfium pour le développement.
pub fn bind_pdfium() -> Result<Pdfium, String> {
    let mut dirs: Vec<PathBuf> = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(PathBuf::from))
        .into_iter()
        .collect();
    for sub in ["bin", "lib"] {
        dirs.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("pdfium").join(sub)); // .dll dans bin, .dylib et .so dans lib
    }
    dirs.iter()
        .find_map(|d| Pdfium::bind_to_library(Pdfium::pdfium_platform_library_name_at_path(d)).ok())
        .or_else(|| Pdfium::bind_to_system_library().ok())
        .map(Pdfium::new)
        .ok_or_else(|| "PDFium est introuvable : pdfium.dll doit être à côté de Nabla.exe. Réinstallez Nabla.".to_string())
}

/// Le même PDF en sombre, toujours vectoriel (texte net et sélectionnable) : papier blanc sous la page,
/// inversion par un fond blanc en mode « différence », éclaircie au niveau de l'aperçu,
/// puis teintes d'origine rendues par une image de la page en mode « teinte ».
pub fn inverted_pdf(pdfium: &Pdfium, data: &[u8]) -> Result<Vec<u8>, PdfiumError> {
    let doc = pdfium.load_pdf_from_byte_slice(data, None)?;
    for mut page in doc.pages().iter() {
        let rect = page.page_size();
        // shortcut: les teintes viennent d'une image de la page à 1,5×, assez pour des aplats de couleur ;
        // un dégradé très fin pourrait baver un peu.
        let colors = page
            .render_with_config(&PdfRenderConfig::new().scale_page_by_factor(1.5))?
            .as_image()?;
        let paper = PdfPagePathObject::new_rect(&doc, rect, None, None, Some(PdfColor::WHITE))?;
        let objects = page.objects_mut();
        objects.insert_object_at_index(0, PdfPageObject::Path(paper))?;
        objects
            .create_path_object_rect(rect, None, None, Some(PdfColor::WHITE))?
            .set_blend_mode(PdfPageObjectBlendMode::Difference)?;
        let light = ((1.0 - INVERT_BLACK_LEVEL) * 255.0).round() as u8;
        objects.create_path_object_rect(rect, None, None, Some(PdfColor::new(255, 255, 255, light)))?;
        objects
            .create_image_object(rect.left(), rect.bottom(), &colors, Some(rect.width()), Some(rect.height()))?
            .set_blend_mode(PdfPageObjectBlendMode::HSLHue)?;
        page.regenerate_content()?;
    }
    doc.save_to_bytes()
}

enum Request {
    Load(u64, Arc<Vec<u8>>),
    Render {
        generation: u64,
        page: usize,
        width: u32,
        invert: bool,
    },
    Export {
        data: Arc<Vec<u8>>,
        path: PathBuf,
        invert: bool,
    },
}

enum Response {
    Loaded(u64, Vec<(f32, f32)>),
    Page {
        generation: u64,
        page: usize,
        width: u32,
        invert: bool,
        image: ColorImage,
    },
    Exported(Result<(), String>),
    Failed(String),
}

/// Le fil de PDFium : un document à la fois, les demandes de rendu périmées sont sautées.
fn worker(rx: mpsc::Receiver<Request>, tx: mpsc::Sender<Response>, ctx: egui::Context) {
    let pdfium = match bind_pdfium() {
        Ok(p) => p,
        Err(e) => {
            let _ = tx.send(Response::Failed(e));
            return;
        }
    };
    let mut doc: Option<(u64, PdfDocument)> = None;
    while let Ok(first) = rx.recv() {
        // Toutes les demandes en attente : seule la plus récente par page compte (redimensionnement continu).
        let mut queue = vec![first];
        queue.extend(rx.try_iter());
        let latest_load = queue.iter().rposition(|r| matches!(r, Request::Load(..)));
        let mut renders: Vec<(u64, usize, u32, bool)> = Vec::new();
        for (i, req) in queue.into_iter().enumerate() {
            match req {
                Request::Load(generation, data) if Some(i) == latest_load => {
                    doc = None;
                    match pdfium.load_pdf_from_byte_vec(data.to_vec(), None) {
                        Ok(d) => {
                            let sizes = d.pages().iter().map(|p| (p.width().value, p.height().value)).collect();
                            let _ = tx.send(Response::Loaded(generation, sizes));
                            doc = Some((generation, d));
                        }
                        Err(e) => {
                            let _ = tx.send(Response::Failed(format!("PDF illisible : {e}")));
                        }
                    }
                }
                Request::Load(..) => {}
                Request::Render {
                    generation,
                    page,
                    width,
                    invert,
                } => {
                    renders.retain(|r| r.1 != page);
                    renders.push((generation, page, width, invert));
                }
                Request::Export { data, path, invert } => {
                    let result = if invert {
                        inverted_pdf(&pdfium, &data)
                            .map_err(|e| e.to_string())
                            .and_then(|d| std::fs::write(&path, d).map_err(|e| e.to_string()))
                    } else {
                        std::fs::write(&path, &*data).map_err(|e| e.to_string())
                    };
                    let _ = tx.send(Response::Exported(result));
                }
            }
        }
        for (generation, index, width, invert) in renders {
            let Some((current, d)) = &doc else { continue };
            if *current != generation {
                continue;
            }
            let Ok(page) = d.pages().get(index as i32) else { continue };
            let Ok(bitmap) = page.render_with_config(&PdfRenderConfig::new().set_target_width(width as i32)) else {
                continue;
            };
            let (w, h) = (bitmap.width() as usize, bitmap.height() as usize);
            let mut rgba = bitmap.as_rgba_bytes();
            if invert {
                invert_rgba(&mut rgba);
            }
            let image = ColorImage::from_rgba_unmultiplied([w, h], &rgba);
            let _ = tx.send(Response::Page {
                generation,
                page: index,
                width,
                invert,
                image,
            });
        }
        ctx.request_repaint();
    }
}

struct PageTexture {
    width: u32,
    invert: bool,
    generation: u64,
    texture: TextureHandle,
}

pub struct PdfView {
    tx: mpsc::Sender<Request>,
    rx: mpsc::Receiver<Response>,
    generation: u64,
    shown: Option<Arc<Vec<u8>>>, // PDF chargé, pour savoir quand une compilation en apporte un nouveau
    sizes: Vec<(f32, f32)>,      // taille des pages en points
    textures: HashMap<usize, PageTexture>,
    requested: HashMap<usize, (u64, u32, bool)>,
    pub error: Option<String>,
    pub export_result: Option<Result<(), String>>,
    flash: Option<(usize, Rect, Instant)>, // page, rectangle en points, début
    scroll_to: Option<f32>,
}

const PAD: f32 = 14.0;

impl PdfView {
    pub fn new(ctx: &egui::Context) -> Self {
        let (tx, worker_rx) = mpsc::channel();
        let (worker_tx, rx) = mpsc::channel();
        let ctx = ctx.clone();
        thread::Builder::new()
            .name("pdfium".into())
            .spawn(move || worker(worker_rx, worker_tx, ctx))
            .unwrap();
        PdfView {
            tx,
            rx,
            generation: 0,
            shown: None,
            sizes: vec![],
            textures: HashMap::new(),
            requested: HashMap::new(),
            error: None,
            export_result: None,
            flash: None,
            scroll_to: None,
        }
    }

    pub fn has_document(&self) -> bool {
        !self.sizes.is_empty()
    }

    pub fn export(&self, data: Arc<Vec<u8>>, path: PathBuf, invert: bool) {
        let _ = self.tx.send(Request::Export { data, path, invert });
    }

    fn receive(&mut self, ctx: &egui::Context) {
        for r in self.rx.try_iter() {
            match r {
                Response::Loaded(generation, sizes) if generation == self.generation => {
                    self.sizes = sizes;
                    self.requested.clear(); // les anciennes images restent affichées jusqu'aux nouvelles : pas de clignement
                    self.error = None;
                }
                Response::Loaded(..) => {}
                Response::Page {
                    generation,
                    page,
                    width,
                    invert,
                    image,
                } if generation == self.generation => {
                    let texture = ctx.load_texture(format!("pdf-{page}"), image, TextureOptions::LINEAR);
                    self.textures.insert(
                        page,
                        PageTexture {
                            width,
                            invert,
                            generation,
                            texture,
                        },
                    );
                }
                Response::Page { .. } => {}
                Response::Exported(r) => self.export_result = Some(r),
                Response::Failed(e) => self.error = Some(e),
            }
        }
    }

    /// Pages à la largeur de la vue (2,5× au plus) ; un double-clic renvoie la page et le point touchés.
    pub fn show(&mut self, ui: &mut egui::Ui, project: &mut Project, invert: bool) {
        self.receive(ui.ctx());
        if let Some(pdf) = &project.pdf {
            if !self.shown.as_ref().is_some_and(|s| Arc::ptr_eq(s, pdf)) {
                self.generation += 1;
                self.shown = Some(pdf.clone());
                let _ = self.tx.send(Request::Load(self.generation, pdf.clone()));
            }
        }
        if self.sizes.is_empty() {
            return;
        }
        let ppp = ui.ctx().pixels_per_point();
        let max_w = self.sizes.iter().map(|s| s.0).fold(1.0, f32::max);
        let scale = ((ui.available_width() - 2.0 * PAD) / max_w).clamp(0.1, 2.5);
        let mut tops = Vec::with_capacity(self.sizes.len());
        let mut y = PAD;
        for (_, h) in &self.sizes {
            tops.push(y);
            y += h * scale + PAD;
        }
        let total = y;

        if let Some(b) = project.sync_box.take() {
            if let Some(&top) = tops.get(b.page.saturating_sub(1)) {
                let height = b.height.max(10.0);
                let rect = Rect::from_min_size(pos2(b.x, b.y - height - 3.0), vec2(b.width.max(40.0), height + 6.0));
                self.flash = Some((b.page - 1, rect, Instant::now()));
                self.scroll_to = Some((top + rect.center().y * scale - ui.available_height() / 2.0).max(0.0));
            }
        }

        let mut area = egui::ScrollArea::both().id_salt("pdf").auto_shrink([false, false]);
        if let Some(offset) = self.scroll_to.take() {
            area = area.vertical_scroll_offset(offset);
        }
        let generation = self.generation;
        area.show_viewport(ui, |ui, viewport| {
            let width = ui.available_width().max(max_w * scale + 2.0 * PAD);
            let (rect, response) = ui.allocate_exact_size(vec2(width, total), Sense::click());
            let painter = ui.painter_at(rect);
            let visible = viewport.translate(rect.min.to_vec2()).expand(viewport.height()); // une page d'avance
            for (i, (w, h)) in self.sizes.iter().enumerate() {
                let page = Rect::from_min_size(
                    pos2(rect.center().x - w * scale / 2.0, rect.min.y + tops[i]),
                    vec2(w * scale, h * scale),
                );
                if !page.intersects(visible) {
                    continue;
                }
                let px = (page.width() * ppp).round() as u32;
                match self.textures.get(&i) {
                    Some(t) => {
                        let uv = Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0));
                        painter.image(t.texture.id(), page, uv, Color32::WHITE);
                    }
                    None => {
                        painter.rect_filled(page, 0.0, if invert { Color32::from_gray(28) } else { Color32::WHITE });
                    }
                }
                let fresh = self
                    .textures
                    .get(&i)
                    .is_some_and(|t| t.width == px && t.invert == invert && t.generation == generation);
                if !fresh && self.requested.get(&i) != Some(&(generation, px, invert)) {
                    self.requested.insert(i, (generation, px, invert));
                    let _ = self.tx.send(Request::Render {
                        generation,
                        page: i,
                        width: px,
                        invert,
                    });
                }
            }
            if let Some((page, r, start)) = self.flash {
                let t = start.elapsed().as_secs_f32();
                if t > 1.5 {
                    self.flash = None;
                } else {
                    let (w, _) = self.sizes[page];
                    let origin = pos2(rect.center().x - w * scale / 2.0, rect.min.y + tops[page]);
                    let shown = Rect::from_min_max(origin + r.min.to_vec2() * scale, origin + r.max.to_vec2() * scale);
                    let alpha = ((1.5 - t) / 1.5 * 90.0) as u8;
                    painter.rect_filled(shown, 2.0, Color32::from_rgba_unmultiplied(255, 200, 0, alpha));
                    ui.ctx().request_repaint();
                }
            }
            // Un double-clic va à la source (comme Overleaf).
            if response.double_clicked() {
                if let Some(p) = response.interact_pointer_pos() {
                    for (i, (w, h)) in self.sizes.iter().enumerate() {
                        let origin = pos2(rect.center().x - w * scale / 2.0, rect.min.y + tops[i]);
                        let local = (p - origin) / scale;
                        if (0.0..=*w).contains(&local.x) && (0.0..=*h).contains(&local.y) {
                            project.show_in_source(i + 1, local.x, local.y);
                        }
                    }
                }
            }
        });
    }
}
