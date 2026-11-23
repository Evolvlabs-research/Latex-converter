// Mêmes tests que app/Tests/NablaTests/Tests.swift, pour que les deux apps se comportent pareil.
use crate::completion::*;
use crate::editor::{Tok, line_chars, line_of, tokens};
use crate::history::*;
use crate::tex::*;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

fn temp(name: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
    std::env::temp_dir().join(format!("n2l-{name}-{nanos}"))
}

fn err(file: Option<&str>, line: Option<usize>, message: &str) -> LogItem {
    LogItem {
        kind: Kind::Error,
        file: file.map(Into::into),
        line,
        message: message.into(),
    }
}

#[test]
fn shared_lists_come_from_swift() {
    assert!(COMMANDS.len() > 200, "environ 230 commandes");
    assert_eq!(
        TEMPLATES.iter().map(|t| t.id).collect::<Vec<_>>(),
        ["article", "rapport", "presentation", "exercices", "formule"]
    );
    assert!(TEMPLATES[0].main.starts_with("\\documentclass[11pt]{article}\n"));
    assert!(TEMPLATES[0].main.ends_with("\\end{document}\n"));
    assert!(
        TEMPLATES[2].main.contains("\\begin{frame}\n  \\titlepage"),
        "indentation gardée"
    );
    assert!(environments().any(|e| e == "align*"));
    assert!(VERSION.split('.').count() == 3);
}

#[test]
fn parse_log_test() {
    let root = temp("log");
    let outside = std::env::temp_dir().join("ailleurs").join("x.sty");
    let log = format!(
        "./chap/a.tex:4: Undefined control sequence.\n\
         LaTeX Warning: Reference `nope' on page 1 undefined on input line 5.\n\
         LaTeX Warning: There were undefined references.\n\
         {}:9: Oops\n",
        outside.display()
    );
    assert_eq!(
        parse_log(&log, &root),
        vec![
            err(Some("chap/a.tex"), Some(4), "Undefined control sequence."),
            LogItem {
                kind: Kind::Warning,
                file: None,
                line: Some(5),
                message: "Reference `nope' on page 1 undefined".into()
            },
            LogItem {
                kind: Kind::Warning,
                file: None,
                line: None,
                message: "There were undefined references".into()
            },
            err(None, Some(9), "Oops"), // fichier hors du projet : pas de lien
        ]
    );
    assert_eq!(
        parse_log("! Emergency stop.\n", &root),
        vec![err(None, None, "Emergency stop.")]
    );
    assert_eq!(
        parse_log("./main.tex:3: Oops\r\n", &root),
        vec![err(Some("main.tex"), Some(3), "Oops")],
        "journal Windows (CRLF)"
    );
}

/// Paquet absent : TeX écrit la cause sur une ligne « ! », puis « Emergency stop » avec le fichier et la ligne.
#[test]
fn parse_log_missing_package() {
    let log = "! LaTeX Error: File `academy.sty' not found.\n\nType X to quit or <RETURN> to proceed,\nEnter file name:\n\
               ./main.tex:3: Emergency stop.\n<read *>\n./main.tex:3:  ==> Fatal error occurred, no output PDF file produced!\n";
    assert_eq!(
        parse_log(log, &temp("p")),
        vec![err(
            Some("main.tex"),
            Some(3),
            "Fichier « academy.sty » introuvable : ajoutez-le au projet (+ › Importer des fichiers) ou installez le paquet qui le fournit."
        )]
    );
}

#[test]
fn command_completions_test() {
    assert_eq!(command_completions("fr", "").first().map(String::as_str), Some("frac"));
    assert_eq!(command_completions("in", "")[..3], ["in", "int", "infty"]); // la commande tapée d'abord
    let file = "\\newcommand{\\RR}{\\mathbb{R}}";
    assert_eq!(command_completions("R", file).first().map(String::as_str), Some("Rightarrow"));
    assert!(command_completions("R", file).contains(&"RR".to_string())); // macro du fichier
    assert!(!command_completions("zz", "\\zz").contains(&"zz".to_string())); // pas la saisie en cours elle-même
    assert_eq!(arity("frac"), Some(2));
    assert_eq!(arity("alpha"), Some(0));
}

#[test]
fn command_prefix_range_test() {
    let text = "x = \\fra y \\\\ab";
    assert_eq!(command_prefix_range(text, 8), Some(5..8)); // « \fra| »
    assert_eq!(command_prefix_range(text, 2), None); // pas de « \ » avant
    assert_eq!(command_prefix_range(text, 5), None); // juste après « \ » : rien tapé encore
    assert_eq!(command_prefix_range("é\\al", 4), Some(2..4));
}

#[test]
fn completion_context_test() {
    let ctx = |t: &str| {
        let n = t.chars().count();
        completion_context(t, n).map(|c| (c.kind, t.chars().skip(c.range.start).take(c.range.len()).collect::<String>()))
    };
    assert_eq!(ctx("x \\fr").unwrap().0, CompletionKind::Command);
    assert_eq!(ctx("voir \\eqref{eq:"), Some((CompletionKind::Label, "eq:".into())));
    assert_eq!(ctx("\\cite{knuth, la").unwrap().1, "la"); // après la virgule
    assert_eq!(ctx("\\cite[p.~3]{kn").unwrap().0, CompletionKind::Citation);
    assert_eq!(ctx("\\begin{al").unwrap().0, CompletionKind::Environment);
    assert_eq!(ctx("\\begin{").unwrap().1, "");
    assert_eq!(ctx("\\textbf{gras"), None);
    assert_eq!(ctx("\\ref{a} et"), None);
}

#[test]
fn completion_sources_and_rank() {
    let s = completion_sources(&[
        (
            "main.tex".into(),
            "\\begin{equation}\\label{eq:x2}\\end{equation} \\label{sec:int}".into(),
        ),
        (
            "refs.bib".into(),
            "@book{knuth, title={T}}\n@Article{ lamport94 ,}\n@comment{pas, une clé}".into(),
        ),
    ]);
    assert_eq!(s.labels, ["eq:x2", "sec:int"]);
    assert_eq!(s.citations, ["knuth", "lamport94"]);
    assert_eq!(s.environments, ["equation"]);
    assert_eq!(rank(["sec:int", "eq:x2", "eq:x2"], "x2"), ["eq:x2"]); // contenu, sans doublon
    assert_eq!(rank(["b", "ab", "a"], "a"), ["ab", "a"]);
}

/// Accepter une proposition : accolades, \end{…} ajouté, curseur au bon endroit.
#[test]
fn accept_completion() {
    let run = |text: &str, word: &str| {
        let ctx = completion_context(text, text.chars().count()).unwrap();
        let (new, cursor, chain) = accept(text, &ctx, word);
        let at = byte_index(&new, cursor);
        (format!("{}|{}", &new[..at], &new[at..]), chain)
    };
    assert_eq!(run("x \\fr", "frac"), ("x \\frac{|}{}".into(), false));
    assert_eq!(run("\\be", "begin"), ("\\begin{|}".into(), true));
    assert_eq!(run("\\begin{al", "align"), ("\\begin{align}\n|\n\\end{align}".into(), false));
    assert_eq!(run("\\ref{eq", "eq:x2"), ("\\ref{eq:x2}|".into(), false));
    assert_eq!(run("\\alp", "alpha"), ("\\alpha|".into(), false));
}

#[test]
fn failure_message_test() {
    let miktex = "latexmk: major issue: So far, no MiKTeX administrator has checked for updates.";
    assert!(failure_message(miktex).starts_with("MiKTeX demande une recherche de mises à jour"));
    assert_eq!(
        failure_message("x\nLatexmk: oups\n\n"),
        "La compilation a échoué. Latexmk: oups"
    );
    let windows =
        "Latexmk: Errors, so I did not complete making targets\r\nReverting Windows console CPs to (in,out) = (437,65001)\r\n";
    assert_eq!(
        failure_message(windows),
        "La compilation a échoué. Latexmk: Errors, so I did not complete making targets"
    );
}

#[test]
fn engine_flag_test() {
    assert_eq!(engine_flag("% !TEX program = XeLaTeX\n\\documentclass{article}"), "-pdfxe");
    assert_eq!(engine_flag("%!TEX TS-program = lualatex"), "-pdflua");
    assert_eq!(engine_flag("\\documentclass{article}"), "-pdf");
}

#[test]
fn child_path_test() {
    let root = temp("child");
    assert_eq!(child_path("chap/a.tex", &root), Some(root.join("chap").join("a.tex")));
    assert_eq!(child_path("../x.tex", &root), None);
    assert_eq!(child_path("chap/../../x.tex", &root), None);
    assert_eq!(child_path("/etc/x.tex", &root), None);
    assert_eq!(child_path("", &root), None);
    if cfg!(windows) {
        assert_eq!(child_path("C:\\x.tex", &root), None);
    }
}

#[test]
fn outline_test() {
    let read = |f: &str| {
        match f {
        "main.tex" => Some("\\section{Intégrales de $\\frac{1}{2}$}\n% \\section{commentée}\n\\input{chap/a}\n\\subsection*{Fin}\n\\verb|\\section{non}|".into()),
        "chap/a.tex" => Some("\\chapter{Suites}".into()),
        _ => None,
    }
    };
    assert_eq!(
        document_outline("main.tex", &read),
        vec![
            OutlineItem {
                level: 2,
                title: "Intégrales de $\\frac{1}{2}$".into(),
                file: "main.tex".into(),
                line: 1
            },
            OutlineItem {
                level: 1,
                title: "Suites".into(),
                file: "chap/a.tex".into(),
                line: 1
            },
            OutlineItem {
                level: 3,
                title: "Fin".into(),
                file: "main.tex".into(),
                line: 4
            },
        ]
    );
}

#[test]
fn history_test() {
    let root = temp("hist");
    let now = SystemTime::now();
    assert!(save_snapshot("v1", &root, "a.tex", Duration::ZERO, now));
    assert!(!save_snapshot("v1", &root, "a.tex", Duration::ZERO, now)); // identique : rien de plus
    assert!(!save_snapshot("v2", &root, "a.tex", Duration::from_secs(120), now)); // trop tôt
    assert!(save_snapshot("v2", &root, "a.tex", Duration::ZERO, now)); // même instant : passe quand même après
    assert_eq!(
        snapshots(&root, "a.tex").iter().map(Snapshot::text).collect::<Vec<_>>(),
        ["v2", "v1"]
    );
    let _ = std::fs::remove_dir_all(history_dir(&root, "a.tex"));
}

#[test]
fn highlight_test() {
    let text = "\\section{A} % note\n\\% x $a$ \\[ \\begin{align}\\\\%c";
    let tok = |s: &str| tokens(text).into_iter().find(|(r, _)| &text[r.clone()] == s).map(|t| t.1);
    assert_eq!(tok("\\section"), Some(Tok::Command));
    assert_eq!(tok("% note"), Some(Tok::Comment));
    assert_eq!(tok("\\%"), Some(Tok::Command)); // un pourcentage, pas un commentaire
    assert_eq!(tok("$"), Some(Tok::Math));
    assert_eq!(tok("\\["), Some(Tok::Math));
    assert_eq!(tok("\\begin{align}"), Some(Tok::Environment));
    assert_eq!(tok("%c"), Some(Tok::Comment)); // « \\% » commente
    let all = tokens(text);
    assert!(all.windows(2).all(|w| w[0].0.end == w[1].0.start) && all.last().unwrap().0.end == text.len());
}

#[test]
fn line_helpers() {
    let text = "a\nbc\n\nd";
    assert_eq!(line_chars(text, 2), 2..5);
    assert_eq!(line_chars(text, 4), 6..8);
    assert_eq!(line_of(text, 3), 2);
    assert_eq!(line_of(text, 7), 4);
}

#[test]
fn relative_path_test() {
    let root = temp("rel");
    std::fs::create_dir_all(root.join("chap")).unwrap();
    std::fs::write(root.join("chap").join("a.tex"), "").unwrap();
    assert_eq!(relative_path("./chap/a.tex", &root).as_deref(), Some("chap/a.tex"));
    assert_eq!(
        relative_path(&root.join("chap").join("a.tex").to_string_lossy(), &root).as_deref(),
        Some("chap/a.tex")
    );
    assert_eq!(relative_path("../x.tex", &root), None);
    let _ = std::fs::remove_dir_all(&root);
}

/// PDF sombre : fond presque noir, encre claire, et un aplat bleu qui reste bleu.
#[test]
fn inverted_pdf_test() {
    use pdfium_render::prelude::*;
    let Ok(pdfium) = crate::pdf::bind_pdfium() else {
        assert!(
            std::env::var("CI").is_err(),
            "PDFium doit être présent en intégration continue"
        );
        return;
    };
    let mut doc = pdfium.create_new_pdf().unwrap();
    let mut page = doc
        .pages_mut()
        .create_page_at_end(PdfPagePaperSize::Custom(PdfPoints::new(100.0), PdfPoints::new(100.0)))
        .unwrap();
    let r = |l, b| PdfRect::new_from_values(b, l, b + 30.0, l + 30.0);
    page.objects_mut()
        .create_path_object_rect(r(10.0, 10.0), None, None, Some(PdfColor::BLACK))
        .unwrap();
    page.objects_mut()
        .create_path_object_rect(r(60.0, 60.0), None, None, Some(PdfColor::new(10, 133, 255, 255)))
        .unwrap();
    drop(page);
    let data = doc.save_to_bytes().unwrap();
    let dark = crate::pdf::inverted_pdf(&pdfium, &data).unwrap();
    let doc = pdfium.load_pdf_from_byte_vec(dark, None).unwrap();
    let page = doc.pages().get(0).unwrap();
    let bitmap = page
        .render_with_config(&PdfRenderConfig::new().set_target_width(100))
        .unwrap();
    let rgba = bitmap.as_rgba_bytes();
    let px = |x: usize, y: usize| {
        let i = (y * 100 + x) * 4; // y depuis le haut
        (rgba[i] as f32 / 255.0, rgba[i + 1] as f32 / 255.0, rgba[i + 2] as f32 / 255.0)
    };
    assert!(px(50, 50).0 < 0.2, "le fond doit être sombre : {:?}", px(50, 50));
    assert!(px(25, 75).0 > 0.8, "l'encre noire doit devenir claire : {:?}", px(25, 75));
    let blue = px(75, 25);
    assert!(blue.2 > blue.0 + 0.2, "le bleu doit rester bleu : {blue:?}");

    // Même rendu à l'écran : l'aperçu ressemble à l'export.
    let mut screen = vec![255, 255, 255, 255, 0, 0, 0, 255, 10, 133, 255, 255];
    crate::pdf::invert_rgba(&mut screen);
    assert!((26..=30).contains(&screen[0]), "fond #1C1C1C : {screen:?}");
    assert!(screen[4] > 240);
    assert!(screen[10] > screen[8] + 50);
}

/// Vrai projet sur le disque : modèle, \input d'un chapitre, erreur localisée, puis SyncTeX dans les deux sens.
/// Ces tests demandent LaTeX (latexmk) : ils sont sautés sans lui, sauf en intégration continue.
fn tex_available() -> bool {
    let ok = find_tool("latexmk").is_some();
    assert!(ok || std::env::var("NABLA_REQUIRE_TEX").is_err(), "latexmk introuvable");
    ok
}

#[test]
fn project_build_and_sync() {
    if !tex_available() {
        return;
    }
    let root = temp("build");
    assert!(create_project(&root, TEMPLATES[0].main).is_ok());
    assert!(
        create_project(&root, TEMPLATES[0].main).is_err(),
        "un dossier existant ne doit pas être réutilisé"
    );
    let out = root.join("build");
    let clean = latexmk(&root, "main.tex", &out);
    assert_eq!(
        clean.log.iter().filter(|i| i.kind == Kind::Error).collect::<Vec<_>>(),
        Vec::<&LogItem>::new()
    );
    assert!(clean.pdf.is_some());

    std::fs::create_dir_all(root.join("chap")).unwrap();
    std::fs::write(root.join("chap/a.tex"), "Bonjour depuis le chapitre.\n\n\\foo\n").unwrap();
    std::fs::write(
        root.join("main.tex"),
        TEMPLATES[0]
            .main
            .replace("\\end{document}", "\\input{chap/a}\n\\end{document}"),
    )
    .unwrap();
    let broken = latexmk(&root, "main.tex", &out);
    assert_eq!(
        broken.log.iter().find(|i| i.kind == Kind::Error),
        Some(&err(Some("chap/a.tex"), Some(3), "Undefined control sequence."))
    );

    std::fs::write(root.join("chap/a.tex"), "Bonjour depuis le chapitre.\n").unwrap();
    latexmk(&root, "main.tex", &out);
    let pdf = out.join("main.pdf");
    let b = synctex_view(&pdf, "chap/a.tex", 1, &root).expect("SyncTeX vers le PDF");
    assert_eq!(b.page, 1);
    assert_eq!(
        synctex_edit(&pdf, b.page, b.x + 5.0, b.y - 2.0, &root),
        Some(("chap/a.tex".into(), 1))
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn templates_compile() {
    if !tex_available() {
        return;
    }
    for t in TEMPLATES {
        let root = temp(t.id);
        create_project(&root, t.main).unwrap();
        let build = latexmk(&root, "main.tex", &root.join("build"));
        assert!(
            build.log.iter().all(|i| i.kind != Kind::Error),
            "{} : {:?}",
            t.name,
            build.log
        );
        assert!(build.pdf.is_some(), "{}", t.name);
        let _ = std::fs::remove_dir_all(&root);
    }
}

#[test]
fn natural_order() {
    let mut v = vec!["chap10.tex", "Chap2.tex", "a.tex"];
    v.sort_by(|a, b| crate::project::natural_cmp(a, b));
    assert_eq!(v, ["a.tex", "Chap2.tex", "chap10.tex"]);
    let _ = Path::new("");
}

/// Gros document (comme le test de l'app Mac : 5 900 lignes) : la coloration reste bien sous une image (16 ms).
#[test]
fn highlight_is_fast() {
    let line = "\\section{Titre} Du texte $x^2 + \\frac{a}{b}$ et \\begin{align} a &= b \\end{align} % note\n";
    let text = line.repeat(5900);
    let start = std::time::Instant::now();
    let n = tokens(&text).len();
    let ms = start.elapsed().as_secs_f64() * 1000.0;
    eprintln!("coloration de 5 900 lignes : {ms:.1} ms ({n} plages)");
    assert!(ms < if cfg!(debug_assertions) { 400.0 } else { 16.0 });
}

/// Une frappe dans ce gros document : coloration et mise en page (egui ne refait que le paragraphe modifié).
#[test]
fn keystroke_is_fast() {
    let line = "\\section{Titre} Du texte $x^2 + \\frac{a}{b}$ et \\begin{align} a &= b \\end{align} % note\n";
    let mut text = line.repeat(5900);
    let ctx = egui::Context::default();
    let mut worst = 0.0f64;
    for i in 0..4 {
        let mut out = ctx.run_ui(egui::RawInput::default(), |ui| {
            let start = std::time::Instant::now();
            let job = crate::editor::layout_job(&text, 13.5, false, egui::Color32::BLACK, &[]);
            let mut job = job;
            job.wrap.max_width = 700.0;
            let galley = ui.fonts_mut(|f| f.layout_job(job));
            assert!(galley.rows.len() >= 5900);
            if i > 0 {
                worst = worst.max(start.elapsed().as_secs_f64() * 1000.0);
            }
        });
        out.textures_delta.clear(); // pas d'écran : les textures de police ne sont envoyées nulle part
        text.insert(text.len() / 2, 'x'); // une frappe au milieu
    }
    eprintln!("frappe dans 5 900 lignes : {worst:.1} ms");
    // marge pour les machines d'intégration continue, plus lentes que ce Mac (environ 12 ms)
    assert!(worst < if cfg!(debug_assertions) { 1000.0 } else { 60.0 });
}
