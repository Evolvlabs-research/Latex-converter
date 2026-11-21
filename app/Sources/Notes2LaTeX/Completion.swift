// Autocomplétion des commandes LaTeX : liste des commandes courantes et choix des propositions.
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

/// Éditeur avec complétion sans insertion provisoire : le choix n'est inséré qu'avec Entrée ou Tab,
/// suivi des accolades des arguments, curseur dans la première.
final class LaTeXTextView: NSTextView {
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        guard flag, movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue else { return }
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: true)
        let args = commandArity[word] ?? 0
        guard args > 0 else { return }
        let at = selectedRange().location
        insertText(String(repeating: "{}", count: args), replacementRange: NSRange(location: at, length: 0))
        setSelectedRange(NSRange(location: at + 1, length: 0))
    }
}
