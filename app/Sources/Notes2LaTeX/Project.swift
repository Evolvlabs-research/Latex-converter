// Un projet = un dossier : ses fichiers, le fichier ouvert (toujours enregistré), la compilation et SyncTeX.
import PDFKit
import SwiftUI

let textExtensions: Set<String> = ["tex", "bib", "sty", "cls", "bst", "txt", "md", "cfg", "def", "ltx"]
let buildExtensions: Set<String> = ["aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "gz", "bbl", "blg", "bcf", "xdv", "nav", "snm"]

func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

@Observable @MainActor final class Project {
    let root: URL
    var files: [String] = []  // chemins relatifs
    var current: String?
    var text = ""  // contenu du fichier ouvert, enregistré à chaque frappe
    var openError: String?  // fichier illisible (pas en UTF-8…) : affiché, jamais réécrit
    var saveError: String?
    var main: String?
    var pdfData: Data?
    var pdf: PDFDocument?
    var log: [LogItem] = []
    var duration: Duration?
    var compiling = false
    var reading = false

    @ObservationIgnored let editor = EditorController()
    @ObservationIgnored weak var pdfView: FittingPDFView?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var compileTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        refresh()
        main = UserDefaults.standard.string(forKey: mainKey).flatMap { files.contains($0) ? $0 : nil } ?? guessMain()
        open(main ?? files.first { textExtensions.contains(ext($0)) })
        compile()
    }

    var name: String { root.lastPathComponent }
    var mainKey: String { "main:" + root.path }
    var outDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notes2latex/" + root.path.replacingOccurrences(of: "/", with: "_"))
    }
    func output(_ suffix: String) -> URL? {
        main.map { outDir.appendingPathComponent((($0 as NSString).lastPathComponent as NSString).deletingPathExtension + suffix) }
    }
    var errors: Int { log.filter { $0.kind == .error }.count }
    var isEditingText: Bool { current.map { textExtensions.contains(ext($0)) } == true && openError == nil }

    var status: String {
        if reading { return "Lecture de la photo…" }
        if let saveError { return saveError }
        if compiling { return "Compilation…" }
        if errors > 0 { return errors == 1 ? "1 erreur" : "\(errors) erreurs" }
        guard let duration else { return "" }
        let time = duration.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
        let warnings = log.count
        return warnings == 0 ? "À jour · \(time)" : "À jour · \(time) · \(warnings) avertissement\(warnings > 1 ? "s" : "")"
    }

    // MARK: Fichiers

    func refresh() {
        // shortcut: liste plate limitée à 2000 fichiers ; un arbre repliable si les projets grossissent.
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [String] = []
        while let url = e?.nextObject() as? URL, found.count < 2000 {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let rel = relativePath(url.path, root: root), !buildExtensions.contains(ext(rel)) else { continue }
            found.append(rel)
        }
        files = found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func guessMain() -> String? {
        let tex = files.filter { ext($0) == "tex" }
        return tex.first { ($0 as NSString).lastPathComponent == "main.tex" }
            ?? tex.first { (try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8))?.contains("\\documentclass") == true }
    }

    func setMain(_ file: String?) {
        main = file
        UserDefaults.standard.set(file, forKey: mainKey)
        compile()
    }

    func open(_ file: String?) {
        current = file
        openError = nil
        text = ""
        guard let file, textExtensions.contains(ext(file)) else { return }
        do { text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) } catch {
            openError = "« \(file) » n'est pas un texte UTF-8 lisible : il n'est pas modifié ici."
        }
    }

    /// Chaque frappe est écrite sur le disque : rien à perdre en quittant.
    func edit(_ new: String) {
        guard let current, isEditingText else { return }
        text = new
        do {
            try new.write(to: root.appendingPathComponent(current), atomically: true, encoding: .utf8)
            saveError = nil
        } catch {
            saveError = "Enregistrement impossible : \(error.localizedDescription)"
        }
        scheduleCompile()
    }

    /// Au retour dans l'app : nouveaux fichiers, et fichier ouvert modifié par un autre éditeur.
    func reload() {
        refresh()
        if let current, !files.contains(current) { open(nil) }
        guard let current, isEditingText,
              let disk = try? String(contentsOf: root.appendingPathComponent(current), encoding: .utf8), disk != text else { return }
        text = disk
        scheduleCompile()
    }

    /// Message d'erreur, ou nil si le fichier est créé et ouvert.
    func createFile(named input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespaces)
        guard var url = childURL(name, root: root) else { return "Nom invalide : « \(name) »." }
        if url.pathExtension.isEmpty { url.appendPathExtension("tex") }
        guard !FileManager.default.fileExists(atPath: url.path) else { return "« \(name) » existe déjà." }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: url, atomically: true, encoding: .utf8)
        } catch { return error.localizedDescription }
        refresh()
        open(relativePath(url.path, root: root))
        return nil
    }

    /// Copie des fichiers dans le projet, sans jamais écraser : « image 2.png » si « image.png » existe.
    func importFiles(_ urls: [URL]) {
        for url in urls where relativePath(url.path, root: root) == nil {
            let stem = url.deletingPathExtension().lastPathComponent, suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
            var dest = root.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = root.appendingPathComponent("\(stem) \(n)\(suffix)")
                n += 1
            }
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        refresh()
    }

    func trash(_ file: String) {
        try? FileManager.default.trashItem(at: root.appendingPathComponent(file), resultingItemURL: nil)
        refresh()
        if file == current { open(nil) }
        if file == main { setMain(guessMain()) }
    }

    // MARK: Compilation

    func scheduleCompile() {
        compileTask?.cancel()
        compileTask = Task {
            try? await Task.sleep(for: .milliseconds(800))  // recompile quand on arrête de taper
            if !Task.isCancelled { compile() }
        }
    }

    func compile() {
        guard let main else {
            log = [LogItem(kind: .error, message: "Aucun document principal : ajoutez un fichier .tex avec \\documentclass.")]
            return
        }
        if compiling { pending = true; return }  // une seule compilation à la fois dans le même dossier
        compiling = true
        Task {
            let start = ContinuousClock.now
            let build = await latexmk(root: root, main: main, outDir: outDir)
            if let data = build.pdf {
                pdfData = data
                pdf = PDFDocument(data: data)
            }
            log = build.log
            duration = start.duration(to: .now)
            compiling = false
            if pending { pending = false; compile() }
        }
    }

    // MARK: SyncTeX

    /// Fait défiler le PDF jusqu'à la ligne du curseur et la fait clignoter.
    func showInPDF() {
        guard let current, let pdf = output(".pdf"), let pdfView else { return }
        let line = editor.currentLine
        Task {
            guard let hit = await synctexView(pdf: pdf, file: current, line: line, root: root),
                  let page = pdfView.document?.page(at: hit.page - 1) else { return }
            let box = page.bounds(for: .mediaBox)
            let rect = CGRect(x: box.minX + hit.x, y: box.maxY - hit.y - 3, width: max(hit.width, 40), height: max(hit.height, 10) + 6)
            pdfView.go(to: rect, on: page)
            if let selection = page.selection(for: rect) { pdfView.setCurrentSelection(selection, animate: true) }
        }
    }

    /// Double-clic dans le PDF : ouvre le fichier source à la bonne ligne.
    func showInSource(page: PDFPage, at point: CGPoint) {
        guard let pdf = output(".pdf"), let index = pdfView?.document?.index(for: page) else { return }
        let box = page.bounds(for: .mediaBox)
        Task {
            guard let hit = await synctexEdit(pdf: pdf, page: index + 1, x: point.x - box.minX, y: box.maxY - point.y, root: root) else { return }
            reveal(file: hit.file, line: hit.line)
        }
    }

    func reveal(file: String?, line: Int?) {
        guard let file, files.contains(file) else { return }
        if file != current {
            editor.pendingLine = line
            open(file)
        } else if let line {
            editor.select(line: line)
        }
    }

    // MARK: Photo

    func readPhoto(_ file: URL) {
        reading = true
        Task {
            defer { reading = false }
            let r = await run(repo.appendingPathComponent(".venv/bin/python").path, ["predict.py", file.path], in: repo)
            guard r.status == 0, let latex = prediction(r.out, file: file.lastPathComponent) else {
                log.insert(LogItem(kind: .error, message: "Lecture impossible de « \(file.lastPathComponent) »."), at: 0)
                return
            }
            editor.insertFormula(latex)
        }
    }
}
