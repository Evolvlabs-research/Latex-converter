// Autocomplétion LaTeX (commandes, labels, citations, environnements) et éditeur qui l'utilise.
import AppKit

/// Commandes courantes, les plus utilisées d'abord (c'est l'ordre des propositions),
/// avec leur nombre d'arguments obligatoires : « frac:2 » insère \frac{}{}.
let latexCommands: [(name: String, args: Int)] = """
frac:2 section:1 subsection:1 begin:1 end:1 textbf:1 emph:1 label:1 ref:1 eqref:1 cite:1 item \
mathbb:1 mathcal:1 mathrm:1 mathbf:1 text:1 sqrt:1 sum prod int iint iiint oint lim infty partial nabla \
alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa lambda mu nu xi pi rho sigma tau \
upsilon phi varphi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega \
left right cdot cdots ldots dots vdots ddots times div pm mp leq geq neq approx equiv sim simeq cong propto \
in notin subset subseteq supset supseteq cup cap setminus emptyset forall exists neg land lor implies iff \
to mapsto rightarrow leftarrow Rightarrow Leftarrow Leftrightarrow longrightarrow Longrightarrow \
sin cos tan exp ln log det dim ker deg gcd arg max min sup inf limsup liminf Re Im ell hbar \
langle rangle lfloor rfloor lceil rceil big Big bigg Bigg \
hat:1 bar:1 vec:1 tilde:1 dot:1 ddot:1 overline:1 underline:1 overbrace:1 underbrace:1 \
dfrac:2 tfrac:2 binom:2 operatorname:1 boldsymbol:1 mathfrak:1 mathsf:1 mathit:1 displaystyle \
quad qquad hspace:1 vspace:1 newline newpage noindent centering hline \
textit:1 texttt:1 textsc:1 textrm:1 textsf:1 footnote:1 url:1 href:2 \
documentclass:1 usepackage:1 title:1 author:1 date:1 maketitle tableofcontents chapter:1 part:1 \
subsubsection:1 paragraph:1 input:1 include:1 includegraphics:1 caption:1 pageref:1 \
newcommand:2 renewcommand:2 DeclareMathOperator:2 bibliography:1 bibliographystyle:1 \
today textwidth linewidth
""".split(whereSeparator: \.isWhitespace).map { entry in
    let parts = entry.split(separator: ":")
    return (String(parts[0]), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
}

let commandArity = Dictionary(latexCommands.map { ($0.name, $0.args) }, uniquingKeysWith: { first, _ in first })

/// Propositions pour « \prefix » : la commande tapée si elle existe (Entrée la garde telle quelle),
/// puis les commandes courantes, puis celles déjà présentes dans le fichier (les macros de l'utilisateur).
func commandCompletions(prefix: String, in text: String) -> [String] {
    let used = text.matches(of: #/\\([A-Za-z]+)/#).map { String($0.1) }
    var seen = Set<String>()
    let exact = commandArity[prefix] != nil ? [prefix] : []
    let rest = (latexCommands.map(\.name) + used).filter { $0.hasPrefix(prefix) && $0 != prefix }
    return Array((exact + rest).filter { seen.insert($0).inserted }.prefix(40))
}

/// Lettres tapées juste après un « \ » et jusqu'au curseur (UTF-16) ; nil si on n'est pas dans une commande.
func commandPrefixRange(_ text: NSString, cursor: Int) -> NSRange? {
    var start = cursor
    while start > 0, let c = UnicodeScalar(text.character(at: start - 1)), CharacterSet.letters.contains(c), c.isASCII { start -= 1 }
    guard start < cursor, start > 0, text.character(at: start - 1) == 0x5C else { return nil }  // 0x5C : « \ »
    return NSRange(location: start, length: cursor - start)
}

// MARK: - Arguments : \ref{…}, \cite{…}, \begin{…}

enum CompletionKind { case command, label, citation, environment }

let labelCommands: Set = ["ref", "eqref", "pageref", "cref", "Cref", "autoref", "nameref", "vref"]
let citeCommands: Set = ["cite", "citep", "citet", "parencite", "textcite", "autocite", "nocite", "footcite"]

let commonEnvironments = """
equation equation* align align* itemize enumerate figure table tabular center cases pmatrix bmatrix matrix \
gather gather* multline split array theorem proof definition lemma proposition corollary remark example \
description quote abstract minipage verbatim frame
""".split(whereSeparator: \.isWhitespace).map(String.init)

/// Ce qu'on complète au curseur : une commande (« \fr »), un label (« \ref{eq: »), une clé de
/// bibliographie (« \cite{knuth, la »), un environnement (« \begin{al »), et la plage à remplacer.
func completionContext(_ text: NSString, cursor: Int) -> (kind: CompletionKind, command: String, range: NSRange)? {
    if let r = commandPrefixRange(text, cursor: cursor) { return (.command, "", r) }
    let lineStart = text.lineRange(for: NSRange(location: min(cursor, text.length), length: 0)).location
    let before = text.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
    guard let m = before.firstMatch(of: #/\\([A-Za-z]+)\*?(?:\[[^\]]*\])?\{([^{}]*)$/#) else { return nil }
    let command = String(m.1)
    let kind: CompletionKind
    if labelCommands.contains(command) { kind = .label }
    else if citeCommands.contains(command) { kind = .citation }
    else if command == "begin" || command == "end" { kind = .environment }
    else { return nil }
    let typed = kind == .citation ? String(m.2.split(separator: ",", omittingEmptySubsequences: false).last ?? "")
        .trimmingCharacters(in: .whitespaces) : String(m.2)
    let length = (typed as NSString).length
    return (kind, command, NSRange(location: cursor - length, length: length))
}

/// Labels, clés de bibliographie et environnements trouvés dans les fichiers du projet.
struct CompletionSources {
    var labels: [String] = []
    var citations: [String] = []
    var environments: [String] = []
}

func completionSources(_ files: [(name: String, text: String)]) -> CompletionSources {
    var s = CompletionSources()
    for (name, text) in files {
        if ext(name) == "bib" {
            s.citations += text.matches(of: #/@(?!comment|string|preamble)\w+\s*\{\s*([^,\s]+)\s*,/#.ignoresCase()).map { String($0.1) }
        } else {
            s.labels += text.matches(of: #/\\label\{([^}]+)\}/#).map { String($0.1) }
            s.environments += text.matches(of: #/\\begin\{([^}]+)\}/#).map { String($0.1) }
        }
    }
    return s
}

/// Ceux qui commencent par ce qui est tapé, puis ceux qui le contiennent ; sans doublons.
func rank(_ items: [String], prefix: String) -> [String] {
    var seen = Set<String>()
    let unique = items.filter { seen.insert($0).inserted }
    let lower = prefix.lowercased()
    let starts = unique.filter { $0.hasPrefix(prefix) }
    let contains = unique.filter { !$0.hasPrefix(prefix) && (lower.isEmpty || $0.lowercased().contains(lower)) }
    return Array((starts + contains).prefix(40))
}

// MARK: - Éditeur

/// Éditeur avec complétion sans insertion provisoire : le choix n'est inséré qu'avec Entrée ou Tab.
/// Une commande reçoit ses accolades (curseur dans la première), un \begin{…} reçoit son \end{…}.
final class LaTeXTextView: NSTextView {
    override var rangeForUserCompletion: NSRange {
        completionContext(string as NSString, cursor: selectedRange().location)?.range ?? super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        guard flag, movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue else { return }
        let context = completionContext(string as NSString, cursor: NSMaxRange(charRange))
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: true)
        switch context?.kind {
        case .command?:
            let args = commandArity[word] ?? 0
            guard args > 0 else { return }
            let at = selectedRange().location
            insertText(String(repeating: "{}", count: args), replacementRange: NSRange(location: at, length: 0))
            setSelectedRange(NSRange(location: at + 1, length: 0))
            if word == "begin" || labelCommands.contains(word) || citeCommands.contains(word) {
                DispatchQueue.main.async { self.complete(nil) }  // enchaîne sur le nom de l'environnement, du label…
            }
        case .environment? where context?.command == "begin":
            closeEnvironment(word)
        case .label?, .citation?, .environment?:
            closeBrace()
        case nil:
            break
        }
    }

    /// Ferme l'argument s'il ne l'est pas déjà, curseur après l'accolade.
    private func closeBrace() {
        let ns = string as NSString
        let at = selectedRange().location
        if at < ns.length, ns.character(at: at) == 0x7D { setSelectedRange(NSRange(location: at + 1, length: 0)); return }
        insertText("}", replacementRange: NSRange(location: at, length: 0))
    }

    /// Après \begin{nom} : ferme l'accolade, ajoute \end{nom} s'il manque, curseur sur la ligne du milieu.
    private func closeEnvironment(_ name: String) {
        let ns = string as NSString
        var at = selectedRange().location
        if at < ns.length, ns.character(at: at) == 0x7D { at += 1 } else {  // 0x7D : « } »
            insertText("}", replacementRange: NSRange(location: at, length: 0))
            at += 1
        }
        let begins = string.components(separatedBy: "\\begin{\(name)}").count, ends = string.components(separatedBy: "\\end{\(name)}").count
        if begins > ends {
            insertText("\n\n\\end{\(name)}", replacementRange: NSRange(location: at, length: 0))
            at += 1
        }
        setSelectedRange(NSRange(location: at, length: 0))
    }
}
