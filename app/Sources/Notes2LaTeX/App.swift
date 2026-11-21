// Éditeur LaTeX avec aperçu PDF compilé en local (pdflatex) et lecture de formules manuscrites (predict.py).
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct Notes2LaTeXApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }  // fenêtre au premier plan aussi avec `swift run`
    var body: some Scene { WindowGroup("notes2latex") { ContentView() } }
}

let template = """
\\documentclass{article}
\\usepackage{amsmath,amssymb}
\\begin{document}
\\[
\\int_0^1 x^2\\,dx = \\frac{1}{3}
\\]
\\end{document}
"""

// shortcut: chemin du dépôt figé à la compilation ; à remplacer par un réglage si l'app quitte ce dossier.
let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct ContentView: View {
    @AppStorage("source") private var source = template  // le texte survit à la fermeture de l'app
    @State private var pdf: PDFDocument?
    @State private var log = ""
    @State private var busy = false

    var body: some View {
        HSplitView {
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 320)
            VStack(spacing: 0) {
                PDFKitView(document: pdf).frame(minWidth: 320)
                if !log.isEmpty {
                    ScrollView {
                        Text(log).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: 140).background(.red.opacity(0.08))
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            if busy { ProgressView().controlSize(.small) }
            Button("Photo → LaTeX", systemImage: "photo") { importPhoto() }.disabled(busy)
            Button("Compiler", systemImage: "play.fill") { compile() }.keyboardShortcut("r").disabled(busy)
        }
        .task { compile() }
    }

    func compile() {
        busy = true
        let src = source
        Task {
            defer { busy = false }
            guard let tex = findTool("pdflatex") else {
                log = "pdflatex introuvable. Installer : brew install --cask mactex-no-gui"
                return
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes2latex")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try src.write(to: dir.appendingPathComponent("doc.tex"), atomically: true, encoding: .utf8)
            } catch { log = error.localizedDescription; return }
            let r = await run(tex, ["-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", "doc.tex"], in: dir)
            if r.status == 0 {
                pdf = PDFDocument(url: dir.appendingPathComponent("doc.pdf"))
                log = ""
            } else {
                log = texError(r.out)
            }
        }
    }

    func importPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, UTType(filenameExtension: "inkml") ?? .xml]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            let python = repo.appendingPathComponent(".venv/bin/python").path
            let r = await run(python, ["predict.py", file.path], in: repo)
            guard r.status == 0, let latex = prediction(r.out, file: file.lastPathComponent) else {
                log = "Lecture impossible :\n" + r.out
                return
            }
            source = insertFormula(latex, into: source)
            compile()
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) { if v.document !== document { v.document = document } }
}

// Les apps lancées depuis le Finder n'ont pas le PATH du terminal : on cherche aux emplacements habituels.
func findTool(_ name: String) -> String? {
    ["/opt/homebrew/bin", "/Library/TeX/texbin", "/usr/local/bin"]
        .map { "\($0)/\(name)" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

func run(_ exe: String, _ args: [String], in dir: URL) async -> (status: Int32, out: String) {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice  // pdflatex ne reste jamais bloqué sur une question
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
}

/// Garde l'erreur de pdflatex (la ligne « ! … » et la ligne fautive), sinon la fin du journal.
func texError(_ out: String) -> String {
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
    let err = lines.drop { !$0.hasPrefix("!") }.prefix(8)
    return (err.isEmpty ? lines.suffix(15) : err).joined(separator: "\n")
}

/// predict.py écrit « nom_du_fichier: formule ».
func prediction(_ out: String, file: String) -> String? {
    out.split(separator: "\n").last { $0.hasPrefix(file + ": ") }.map { String($0.dropFirst(file.count + 2)) }
}

/// Ajoute la formule en mode display juste avant \end{document}.
func insertFormula(_ latex: String, into source: String) -> String {
    let block = "\\[\n\(latex)\n\\]\n"
    guard let end = source.range(of: "\\end{document}", options: .backwards) else { return source + "\n" + block }
    return source.replacingCharacters(in: end.lowerBound..<end.lowerBound, with: block)
}
