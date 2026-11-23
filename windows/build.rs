// Les listes partagées avec l'app Mac (commandes, environnements, modèles de projet) et le numéro de version
// sont lus dans les sources Swift et dans CHANGELOG.md : une modification côté Mac arrive ici à la compilation.
use std::{env, fs, path::Path};

fn main() {
    let swift = Path::new("../app/Sources/Nabla");
    let completion = read(&swift.join("Completion.swift"));
    let tex = read(&swift.join("TeX.swift"));
    let changelog = read(Path::new("../CHANGELOG.md"));

    let commands = swift_string(&completion, "let latexCommands");
    let environments = swift_string(&completion, "let commonEnvironments");
    let article = swift_string(&tex, "let newProjectTemplate");

    let mut templates = String::new();
    let re = regex::Regex::new(
        r#"ProjectTemplate\(id: "([^"]+)", name: "([^"]+)", icon: "[^"]*", detail: "([^"]+)", main: (newProjectTemplate|""")"#,
    )
    .unwrap();
    for m in re.captures_iter(&tex) {
        let main = if &m[4] == "newProjectTemplate" {
            article.clone()
        } else {
            parse_block(&tex[m.get(4).unwrap().start()..])
        };
        templates += &format!(
            "    Template {{ id: {:?}, name: {:?}, detail: {:?}, main: {:?} }},\n",
            &m[1], &m[2], &m[3], main
        );
    }
    assert!(
        templates.matches("Template {").count() >= 5,
        "modèles de projet introuvables dans TeX.swift"
    );

    let version = changelog
        .lines()
        .find_map(|l| l.strip_prefix("## v"))
        .and_then(|l| l.split_whitespace().next())
        .expect("aucune version « ## vX.Y.Z » dans CHANGELOG.md");

    let out = format!(
        "pub const LATEX_COMMANDS: &str = {commands:?};\npub const COMMON_ENVIRONMENTS: &str = {environments:?};\n\
         pub const VERSION: &str = {version:?};\npub const TEMPLATES: &[Template] = &[\n{templates}];\n"
    );
    fs::write(Path::new(&env::var("OUT_DIR").unwrap()).join("shared.rs"), out).unwrap();

    println!("cargo:rerun-if-changed=../app/Sources/Nabla/Completion.swift");
    println!("cargo:rerun-if-changed=../app/Sources/Nabla/TeX.swift");
    println!("cargo:rerun-if-changed=../CHANGELOG.md");
    // Icône et version de Nabla.exe (compilé sous Windows seulement : il faut rc.exe)
    if env::var("CARGO_CFG_WINDOWS").is_ok() && env::var("HOST").is_ok_and(|h| h.contains("windows")) {
        winresource::WindowsResource::new()
            .set_icon("assets/nabla.ico")
            .set("ProductName", "Nabla")
            .set("FileDescription", "Nabla")
            .set("ProductVersion", version)
            .set("FileVersion", version)
            .compile()
            .unwrap();
    }
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| {
        panic!(
            "{} illisible ({e}) : windows/ se construit dans le dépôt de Nabla",
            path.display()
        )
    })
}

/// Chaîne Swift multiligne (""" … """) qui suit `start`.
fn swift_string(source: &str, start: &str) -> String {
    let at = source
        .find(start)
        .unwrap_or_else(|| panic!("« {start} » introuvable dans les sources Swift"));
    let open = source[at..].find("\"\"\"").expect("chaîne multiligne attendue") + at;
    parse_block(&source[open..])
}

/// `text` commence par """ : contenu sans l'indentation du """ fermant, échappements Swift résolus.
fn parse_block(text: &str) -> String {
    let lines: Vec<&str> = text.lines().skip(1).collect();
    let end = lines
        .iter()
        .position(|l| l.trim_start().starts_with("\"\"\""))
        .expect("\"\"\" fermant introuvable");
    let indent = lines[end].len() - lines[end].trim_start().len();
    let mut raw = String::new();
    for (i, line) in lines[..end].iter().enumerate() {
        let line = line.get(indent..).unwrap_or("");
        let trailing = line.len() - line.trim_end_matches('\\').len();
        if trailing % 2 == 1 {
            raw += &line[..line.len() - 1]; // « \ » en fin de ligne : la ligne continue
        } else {
            raw += line;
            if i + 1 < end {
                raw.push('\n');
            }
        }
    }
    let mut out = String::new();
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('\\') => out.push('\\'),
            Some('"') => out.push('"'),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            other => panic!("échappement Swift non pris en charge : \\{other:?}"),
        }
    }
    out
}
