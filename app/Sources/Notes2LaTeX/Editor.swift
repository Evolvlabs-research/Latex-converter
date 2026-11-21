// Éditeur LaTeX : NSTextView sans substitutions typographiques, avec coloration syntaxique.
import AppKit
import SwiftUI

/// Donne au projet l'accès au NSTextView : aller à une ligne, ligne du curseur, insérer avec annulation.
@MainActor final class EditorController {
    weak var textView: NSTextView?
    var pendingLine: Int?  // ligne à montrer dès que le fichier demandé est affiché

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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
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
        tv.typingAttributes = baseAttributes
        tv.string = text
        highlight(tv.textStorage!)
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
            tv.string = text
            highlight(tv.textStorage!)
            tv.undoManager?.removeAllActions()  // autre fichier, ou modifié ailleurs : l'historique ne s'applique plus
        }
        if let line = controller.pendingLine {
            controller.pendingLine = nil
            controller.select(line: line)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            highlight(tv.textStorage!)
            text.wrappedValue = tv.string
        }
    }
}

let baseAttributes: [NSAttributedString.Key: Any] = {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.25
    return [
        .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
        .foregroundColor: NSColor.textColor,
        .paragraphStyle: paragraph,
    ]
}()

// Couleurs système : elles s'adaptent seules au mode clair et au mode sombre.
// Dans l'ordre : une règle plus bas l'emporte sur celles du dessus.
let syntax: [(NSRegularExpression, NSColor)] = [
    (try! NSRegularExpression(pattern: #"[{}\[\]]"#), .tertiaryLabelColor),
    (try! NSRegularExpression(pattern: #"\\[A-Za-z@]+\*?|\\."#), .systemBlue),
    (try! NSRegularExpression(pattern: #"\\(?:begin|end)\{[^}]*\}"#), .systemPurple),
    (try! NSRegularExpression(pattern: #"\$\$?|\\\[|\\\]|\\\(|\\\)"#), .systemOrange),
    (try! NSRegularExpression(pattern: #"(?<!\\)%.*$"#, options: .anchorsMatchLines), .secondaryLabelColor),
]

func highlight(_ storage: NSTextStorage) {
    let all = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: all)
    for (regex, color) in syntax {
        regex.enumerateMatches(in: storage.string, range: all) { match, _, _ in
            if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
        }
    }
    storage.endEditing()
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
