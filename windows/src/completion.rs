// Autocomplétion LaTeX : commandes, labels, citations, environnements. Pendant de Completion.swift ;
// les listes viennent de Completion.swift (voir build.rs). Les positions sont en caractères, comme dans egui.
use crate::tex::{COMMON_ENVIRONMENTS, LATEX_COMMANDS, ext};
use regex::Regex;
use std::{collections::HashMap, collections::HashSet, ops::Range, sync::LazyLock};

/// Commandes courantes, les plus utilisées d'abord, avec leur nombre d'arguments : « frac:2 » insère \frac{}{}.
pub static COMMANDS: LazyLock<Vec<(String, usize)>> = LazyLock::new(|| {
    LATEX_COMMANDS
        .split_whitespace()
        .map(|e| match e.split_once(':') {
            Some((n, a)) => (n.to_string(), a.parse().unwrap_or(0)),
            None => (e.to_string(), 0),
        })
        .collect()
});

pub static ARITY: LazyLock<HashMap<&'static str, usize>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    for (n, a) in COMMANDS.iter() {
        m.entry(n.as_str()).or_insert(*a);
    }
    m
});

pub fn arity(name: &str) -> Option<usize> {
    ARITY.get(name).copied()
}

pub fn environments() -> impl Iterator<Item = &'static str> {
    COMMON_ENVIRONMENTS.split_whitespace()
}

pub const LABEL_COMMANDS: &[&str] = &["ref", "eqref", "pageref", "cref", "Cref", "autoref", "nameref", "vref"];
pub const CITE_COMMANDS: &[&str] = &[
    "cite",
    "citep",
    "citet",
    "parencite",
    "textcite",
    "autocite",
    "nocite",
    "footcite",
];

/// Propositions pour « \prefix » : la commande tapée si elle existe (Entrée la garde telle quelle),
/// puis les commandes courantes, puis celles déjà présentes dans le fichier (les macros de l'utilisateur).
pub fn command_completions(prefix: &str, text: &str) -> Vec<String> {
    static USED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\([A-Za-z]+)").unwrap());
    let mut seen = HashSet::new();
    let exact = arity(prefix).map(|_| prefix);
    let rest = COMMANDS
        .iter()
        .map(|(n, _)| n.as_str())
        .chain(USED.captures_iter(text).map(|c| c.get(1).unwrap().as_str()))
        .filter(|n| n.starts_with(prefix) && *n != prefix);
    exact
        .into_iter()
        .chain(rest)
        .filter(|n| seen.insert(*n))
        .take(40)
        .map(str::to_string)
        .collect()
}

/// Octet du caractère n° `cursor`.
pub fn byte_index(text: &str, cursor: usize) -> usize {
    text.char_indices().nth(cursor).map_or(text.len(), |(b, _)| b)
}

/// Lettres tapées juste après un « \ » et jusqu'au curseur ; None si on n'est pas dans une commande.
pub fn command_prefix_range(text: &str, cursor: usize) -> Option<Range<usize>> {
    let end = byte_index(text, cursor);
    let bytes = text.as_bytes();
    let mut start = end;
    while start > 0 && bytes[start - 1].is_ascii_alphabetic() {
        start -= 1;
    }
    (start < end && start > 0 && bytes[start - 1] == b'\\').then(|| cursor - (end - start)..cursor)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CompletionKind {
    Command,
    Label,
    Citation,
    Environment,
}

#[derive(Clone, PartialEq, Debug)]
pub struct Context {
    pub kind: CompletionKind,
    pub command: String,
    pub range: Range<usize>, // caractères à remplacer
}

/// Ce qu'on complète au curseur : une commande (« \fr »), un label (« \ref{eq: »), une clé de
/// bibliographie (« \cite{knuth, la »), un environnement (« \begin{al »), et la plage à remplacer.
pub fn completion_context(text: &str, cursor: usize) -> Option<Context> {
    static ARG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\([A-Za-z]+)\*?(?:\[[^\]]*\])?\{([^{}]*)$").unwrap());
    if let Some(range) = command_prefix_range(text, cursor) {
        return Some(Context {
            kind: CompletionKind::Command,
            command: String::new(),
            range,
        });
    }
    let end = byte_index(text, cursor);
    let line_start = text[..end].rfind('\n').map_or(0, |i| i + 1);
    let m = ARG.captures(&text[line_start..end])?;
    let command = &m[1];
    let kind = if LABEL_COMMANDS.contains(&command) {
        CompletionKind::Label
    } else if CITE_COMMANDS.contains(&command) {
        CompletionKind::Citation
    } else if command == "begin" || command == "end" {
        CompletionKind::Environment
    } else {
        return None;
    };
    let typed = if kind == CompletionKind::Citation {
        m[2].rsplit(',').next().unwrap_or("").trim_start() // après la dernière virgule
    } else {
        &m[2]
    };
    let length = typed.chars().count();
    Some(Context {
        kind,
        command: command.to_string(),
        range: cursor - length..cursor,
    })
}

/// Labels, clés de bibliographie et environnements trouvés dans les fichiers du projet.
#[derive(Default, Debug, PartialEq)]
pub struct Sources {
    pub labels: Vec<String>,
    pub citations: Vec<String>,
    pub environments: Vec<String>,
}

pub fn completion_sources(files: &[(String, String)]) -> Sources {
    static BIB: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"@(\w+)\s*\{\s*([^,\s]+)\s*,").unwrap());
    static LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\label\{([^}]+)\}").unwrap());
    static BEGIN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\begin\{([^}]+)\}").unwrap());
    let mut s = Sources::default();
    for (name, text) in files {
        if ext(name) == "bib" {
            s.citations.extend(
                BIB.captures_iter(text)
                    .filter(|c| {
                        let t = c[1].to_lowercase();
                        !["comment", "string", "preamble"].iter().any(|p| t.starts_with(p))
                    })
                    .map(|c| c[2].to_string()),
            );
        } else {
            s.labels.extend(LABEL.captures_iter(text).map(|c| c[1].to_string()));
            s.environments.extend(BEGIN.captures_iter(text).map(|c| c[1].to_string()));
        }
    }
    s
}

/// Ceux qui commencent par ce qui est tapé, puis ceux qui le contiennent ; sans doublons.
pub fn rank<'a>(items: impl IntoIterator<Item = &'a str>, prefix: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    let unique: Vec<&str> = items.into_iter().filter(|i| seen.insert(*i)).collect();
    let lower = prefix.to_lowercase();
    let starts = unique.iter().filter(|i| i.starts_with(prefix));
    let contains = unique
        .iter()
        .filter(|i| !i.starts_with(prefix) && (lower.is_empty() || i.to_lowercase().contains(&lower)));
    starts.chain(contains).take(40).map(|s| s.to_string()).collect()
}

/// Propositions pour un contexte donné.
pub fn suggestions(ctx: &Context, typed: &str, text: &str, sources: &Sources) -> Vec<String> {
    match ctx.kind {
        CompletionKind::Command => command_completions(typed, text),
        CompletionKind::Label => rank(sources.labels.iter().map(String::as_str), typed),
        CompletionKind::Citation => rank(sources.citations.iter().map(String::as_str), typed),
        CompletionKind::Environment => {
            // le fichier contient déjà « \begin{al » en cours de frappe : pas « al » dans la liste
            let mut all: Vec<&str> = environments().collect();
            all.extend(sources.environments.iter().map(String::as_str).filter(|e| *e != typed));
            rank(all, typed)
        }
    }
}

/// Texte inséré à la place de `range` quand on accepte `word`, et position du curseur (en caractères depuis
/// le début du texte) : une commande reçoit ses accolades (curseur dans la première), un \begin{…} reçoit son
/// \end{…}, un label ou une clé ferme son accolade. Rend aussi s'il faut enchaîner sur une autre complétion.
pub fn accept(text: &str, ctx: &Context, word: &str) -> (String, usize, bool) {
    let start = byte_index(text, ctx.range.start);
    let end = byte_index(text, ctx.range.end);
    let (before, after) = (&text[..start], &text[end..]);
    let at = ctx.range.start + word.chars().count();
    let mut insert = word.to_string();
    let mut cursor = at;
    let mut chain = false;
    match ctx.kind {
        CompletionKind::Command => {
            let args = arity(word).unwrap_or(0);
            if args > 0 {
                insert += &"{}".repeat(args);
                cursor = at + 1;
                chain = word == "begin" || LABEL_COMMANDS.contains(&word) || CITE_COMMANDS.contains(&word);
            }
        }
        CompletionKind::Environment if ctx.command == "begin" => {
            if !after.starts_with('}') {
                insert.push('}');
            }
            cursor = at + 1;
            let full = format!("{before}{insert}{after}");
            if full.matches(&format!("\\begin{{{word}}}")).count() > full.matches(&format!("\\end{{{word}}}")).count() {
                let skip = if after.starts_with('}') { 1 } else { 0 };
                let (closing, rest) = after.split_at(skip);
                let text = format!("{before}{insert}{closing}\n\n\\end{{{word}}}{rest}");
                return (text, at + 2, false); // curseur sur la ligne du milieu
            }
        }
        _ => {
            if !after.starts_with('}') {
                insert.push('}');
            }
            cursor = at + 1;
        }
    }
    (format!("{before}{insert}{after}"), cursor, chain)
}
