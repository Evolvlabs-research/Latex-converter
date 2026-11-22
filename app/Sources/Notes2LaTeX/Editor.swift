// Éditeur LaTeX : NSTextView sans substitutions typographiques, avec coloration syntaxique.
import AppKit
import SwiftUI

/// Donne au projet l'accès au NSTextView : aller à une ligne, ligne du curseur, insérer avec annulation.
@MainActor final class EditorController {
    weak var textView: NSTextView?
    var pendingLine: Int?  // ligne à montrer dès que le fichier demandé est affiché
    var sources: () -> CompletionSources = { CompletionSources() }  // labels, clés, environnements du projet
    var onPhoto: (URL) -> Void = { _ in }  // image collée ou déposée dans l'éditeur

    var currentLine: Int {
        guard let tv = textView else { return 1 }
        let ns = tv.string as NSString
        return ns.substring(to: min(tv.selectedRange().location, ns.length)).filter { $0 == "\n" }.count + 1
    }

    func select(line: Int) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var start = 0
        for _ in 1..<max(line, 1) where start < ns.length { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
        let range = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
    }

    func insertFormula(_ latex: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let at = insertionPoint(in: tv.string, cursor: tv.selectedRange().location)
        let newline = at > 0 && ns.character(at: at - 1) != 10 ? "\n" : ""
        let block = newline + "\\[\n" + latex + "\n\\]\n"
        tv.insertText(block, replacementRange: NSRange(location: at, length: 0))
        let formula = NSRange(location: at + (newline + "\\[\n" as NSString).length, length: (latex as NSString).length)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(formula)  // formule sélectionnée : on voit ce qui a été lu, prête à corriger
        tv.scrollRangeToVisible(formula)
    }
}

struct LaTeXEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: EditorController
    @AppStorage("editorFontSize") private var fontSize = defaultEditorFontSize  // ⌘+ / ⌘− / ⌘0

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let tv = LaTeXTextView(usingTextLayoutManager: false)  // TextKit 1 : la marge des numéros lit le layoutManager
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        scroll.verticalRulerView = LineNumberRuler(textView: tv)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.usesFindBar = true  // ⌘F : rechercher et remplacer dans le fichier
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator  // recolore seulement les paragraphes modifiés
        tv.onPhoto = { controller.onPhoto($0) }
        tv.isRichText = false
        tv.allowsUndo = true
        // LaTeX : ni guillemets courbes, ni tirets longs, ni correction automatique.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.textContainerInset = NSSize(width: 18, height: 18)
        tv.typingAttributes = baseAttributes()
        tv.string = text  // coloré par le délégué du texte
        controller.textView = tv
        if let line = controller.pendingLine {
            controller.pendingLine = nil
            DispatchQueue.main.async { controller.select(line: line) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.string != text {
            tv.string = text  // coloré par le délégué du texte
            tv.undoManager?.removeAllActions()  // autre fichier, ou modifié ailleurs : l'historique ne s'applique plus
        }
        if (tv.typingAttributes[.font] as? NSFont).map({ Double($0.pointSize) }) != fontSize {  // taille du texte changée dans le menu
            tv.typingAttributes = baseAttributes()
            highlight(tv.textStorage!)
            scroll.verticalRulerView?.needsDisplay = true
        }
        if let line = controller.pendingLine {
            controller.pendingLine = nil
            controller.select(line: line)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let text: Binding<String>
        let controller: EditorController
        private var typed: Character?  // caractère tapé au clavier (pas un collage ni une complétion)
        init(text: Binding<String>, controller: EditorController) {
            self.text = text
            self.controller = controller
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
            typed = string?.count == 1 ? string?.first : nil
            return true
        }

        // Toute modification du texte (frappe, collage, annulation, complétion, autre fichier) passe ici.
        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range: NSRange, changeInLength: Int) {
            guard mask.contains(.editedCharacters) else { return }
            highlight(storage, in: (storage.string as NSString).paragraphRange(for: range))
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            // Frappe dans « \fr », « \ref{ », « \cite{ », « \begin{ » : ouvrir la liste (après la frappe, pas pendant).
            guard let typed, tv.selectedRange().length == 0,
                  let context = completionContext(tv.string as NSString, cursor: tv.selectedRange().location) else { return }
            if context.kind == .command ? typed.isLetter : !" }".contains(typed) {
                DispatchQueue.main.async { tv.complete(nil) }
            }
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let ns = textView.string as NSString
            guard let context = completionContext(ns, cursor: NSMaxRange(charRange)), context.range == charRange else { return [] }
            index?.pointee = 0
            let typed = ns.substring(with: charRange)
            switch context.kind {
            case .command: return commandCompletions(prefix: typed, in: textView.string)
            case .label: return rank(controller.sources().labels, prefix: typed)
            case .citation: return rank(controller.sources().citations, prefix: typed)
            case .environment:  // le fichier contient déjà « \begin{al » en cours de frappe : pas « al » dans la liste
                return rank(commonEnvironments + controller.sources().environments.filter { $0 != typed }, prefix: typed)
            }
        }
    }
}

let defaultEditorFontSize = 13.5
let editorFontSizes = 10.0...24.0

func editorFontSize() -> Double {
    let size = UserDefaults.standard.double(forKey: "editorFontSize")
    return size > 0 ? min(max(size, editorFontSizes.lowerBound), editorFontSizes.upperBound) : defaultEditorFontSize
}

func baseAttributes() -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.25
    return [
        .font: NSFont.monospacedSystemFont(ofSize: editorFontSize(), weight: .regular),
        .foregroundColor: NSColor.textColor,
        .paragraphStyle: paragraph,
    ]
}

// Couleurs système : elles s'adaptent seules au mode clair et au mode sombre, avec un contraste suffisant
// (pas de tertiaryLabelColor, trop pâle pour du texte). Les commentaires sont aussi en italique :
// la couleur seule ne suffit pas à les distinguer. Une règle plus bas l'emporte sur celles du dessus.
// `group` : partie de la correspondance à colorer (0 : toute).
let syntax: [(regex: NSRegularExpression, color: NSColor, italic: Bool, group: Int)] = [
    (try! NSRegularExpression(pattern: #"[{}\[\]]"#), .secondaryLabelColor, false, 0),
    (try! NSRegularExpression(pattern: #"\\[A-Za-z@]+\*?|\\."#), .systemBlue, false, 0),
    (try! NSRegularExpression(pattern: #"\\(?:begin|end)\{[^}]*\}"#), .systemPurple, false, 0),
    (try! NSRegularExpression(pattern: #"\$\$?|\\\[|\\\]|\\\(|\\\)"#), .systemOrange, false, 0),
    // Commentaire : « % » précédé d'un nombre pair de « \ » (« \% » est un pourcentage, « \\% » un commentaire).
    (try! NSRegularExpression(pattern: #"(?:^|[^\\])(?:\\\\)*(%.*)$"#, options: .anchorsMatchLines), .secondaryLabelColor, true, 1),
]

/// Colore `range` (des paragraphes entiers : aucune règle ne déborde sur la ligne suivante), ou tout le texte.
func highlight(_ storage: NSTextStorage, in range: NSRange? = nil) {
    let target = range ?? NSRange(location: 0, length: storage.length)
    let base = baseAttributes()
    let italic = NSFontManager.shared.convert(base[.font] as! NSFont, toHaveTrait: .italicFontMask)
    if range == nil { storage.beginEditing() }  // pas pendant le traitement d'une modification par le délégué
    storage.setAttributes(base, range: target)
    for rule in syntax {
        rule.regex.enumerateMatches(in: storage.string, range: target) { match, _, _ in
            guard let r = match?.range(at: rule.group), r.location != NSNotFound else { return }
            storage.addAttribute(.foregroundColor, value: rule.color, range: r)
            if rule.italic { storage.addAttribute(.font, value: italic, range: r) }
        }
    }
    if range == nil { storage.endEditing() }
}

/// Début (en UTF-16) de chaque ligne : calculé une fois par modification, pas à chaque dessin de la marge.
func lineStarts(_ text: NSString) -> [Int] {
    let n = text.length
    var chars = [unichar](repeating: 0, count: n)
    text.getCharacters(&chars, range: NSRange(location: 0, length: n))
    var starts = [0]
    for i in 0..<n where chars[i] == 10 { starts.append(i + 1) }
    return starts
}

/// Numéro (à partir de 1) de la ligne qui contient `location`, par recherche dichotomique.
func lineNumber(at location: Int, in starts: [Int]) -> Int {
    var low = 0, high = starts.count
    while low < high {
        let mid = (low + high) / 2
        if starts[mid] <= location { low = mid + 1 } else { high = mid }
    }
    return low
}

/// Où insérer une formule (en UTF-16, comme NSTextView) : au début de la ligne du curseur
/// s'il est dans le corps du document (ou dans un fichier inclus), sinon juste avant \end{document}.
func insertionPoint(in text: String, cursor: Int) -> Int {
    let ns = text as NSString
    let lineStart = ns.lineRange(for: NSRange(location: min(cursor, ns.length), length: 0)).location
    let end = ns.range(of: "\\end{document}", options: .backwards)
    guard end.location != NSNotFound else { return lineStart }
    let begin = ns.range(of: "\\begin{document}")
    let bodyStart = begin.location == NSNotFound ? 0 : NSMaxRange(ns.lineRange(for: begin))
    return cursor >= bodyStart && cursor <= end.location ? lineStart : end.location
}

/// Numéros de ligne dans la marge : un par ligne du fichier (une ligne coupée à l'affichage garde un seul numéro),
/// celui de la ligne du curseur plus visible.
final class LineNumberRuler: NSRulerView {
    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification,
                                               object: textView)
        // Toute modification, y compris un autre fichier chargé par programme : les débuts de ligne sont à recalculer.
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSTextStorage.didProcessEditingNotification,
                                               object: textView.textStorage)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private var starts: [Int]?

    @objc private func redraw() { needsDisplay = true }

    @objc private func textChanged() {
        starts = nil
        needsDisplay = true
    }

    // Depuis macOS 14 une vue peut dessiner hors de ses bords : sans ça, le fond de la marge recouvrait l'éditeur.
    override var clipsToBounds: Bool { get { true } set {} }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        let ns = tv.string as NSString
        let visible = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: tv.visibleRect, in: container), actualGlyphRange: nil)
        let cursor = tv.selectedRange().location
        let starts = self.starts ?? lineStarts(ns)
        self.starts = starts
        var line = lineNumber(at: visible.location, in: starts)
        var index = visible.location
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, editorFontSize() * 0.8), weight: .regular)

        func label(_ n: Int, at y: CGFloat, current: Bool) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: current ? NSColor.labelColor : NSColor.secondaryLabelColor]
            let s = "\(n)" as NSString
            let size = s.size(withAttributes: attrs)
            let top = convert(NSPoint(x: 0, y: y + tv.textContainerInset.height), from: tv).y
            s.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: top + 3), withAttributes: attrs)
        }

        while index < NSMaxRange(visible) {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
            label(line, at: fragment.minY, current: cursor >= range.location && cursor < NSMaxRange(range))
            line += 1
            index = NSMaxRange(range)
        }
        // Ligne vide après le dernier saut de ligne : elle a aussi son numéro.
        if NSMaxRange(visible) == ns.length, ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
            label(line, at: lm.extraLineFragmentRect.minY, current: cursor == ns.length)
        }
    }
}
