// Un projet = un dossier : ses fichiers, le fichier ouvert (toujours enregistré), la compilation et SyncTeX.
import PDFKit
import SwiftUI

let textExtensions: Set<String> = ["tex", "bib", "sty", "cls", "bst", "txt", "md", "cfg", "def", "ltx"]
let buildExtensions: Set<String> = ["aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "gz", "bbl", "blg", "bcf", "xdv", "nav", "snm"]

func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

/// Lue sur le disque à chaque appel (les valeurs de `URL.resourceValues` restent en cache après une écriture).
func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

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
    var outline: [OutlineItem] = []

    @ObservationIgnored let editor = EditorController()
    @ObservationIgnored weak var pdfView: FittingPDFView?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var compileTask: Task<Void, Never>?
    @ObservationIgnored private var knownDate: Date?  // date du fichier ouvert la dernière fois qu'on l'a lu ou écrit

    init(root: URL) {
        self.root = root
        refresh()
        main = UserDefaults.standard.string(forKey: mainKey).flatMap { files.contains($0) ? $0 : nil } ?? guessMain()
        open(main ?? files.first { textExtensions.contains(ext($0)) })
        editor.sources = { [weak self] in self?.projectSources() ?? CompletionSources() }
        compile()
        Task { [weak self] in  // un autre éditeur ou Git peut modifier le fichier ouvert à tout moment
            while true {
                // Au premier plan seulement : au retour dans l'app, reload() relit de toute façon le fichier.
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(500))
                guard let self else { return }
                if NSApp.isActive { self.checkDisk() }
            }
        }
    }

    var name: String { root.lastPathComponent }
    var mainKey: String { "main:" + root.path }
    var outDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nabla/" + root.path.replacingOccurrences(of: "/", with: "_"))
    }
    func output(_ suffix: String) -> URL? {
        main.map { outDir.appendingPathComponent((($0 as NSString).lastPathComponent as NSString).deletingPathExtension + suffix) }
    }
    var errors: Int { log.filter { $0.kind == .error }.count }
    var isEditingText: Bool { current.map { textExtensions.contains(ext($0)) } == true && openError == nil }

    var status: String {
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
        let url = root.appendingPathComponent(file)
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            openError = "« \(file) » n'est pas un texte UTF-8 lisible : il n'est pas modifié ici."
            return
        }
        knownDate = modificationDate(url)
        saveSnapshot(text, root: root, file: file)  // l'état d'avant la séance, pour pouvoir y revenir
    }

    /// Chaque frappe est écrite sur le disque : rien à perdre en quittant.
    func edit(_ new: String) {
        guard let current, isEditingText else { return }
        let url = root.appendingPathComponent(current)
        // Modifié ailleurs depuis notre dernière lecture : on garde la version du disque, la nôtre va dans l'historique.
        if modificationDate(url) != knownDate, let disk = try? String(contentsOf: url, encoding: .utf8), disk != text {
            saveSnapshot(new, root: root, file: current)
            text = disk
            knownDate = modificationDate(url)
            saveError = "« \(current) » a été modifié ailleurs : version du disque rechargée, la vôtre est dans l'historique."
            scheduleCompile()
            return
        }
        text = new
        do {
            try new.write(to: url, atomically: true, encoding: .utf8)
            knownDate = modificationDate(url)
            saveError = nil
        } catch {
            saveError = "Enregistrement impossible : \(error.localizedDescription)"
        }
        saveSnapshot(new, root: root, file: current, minInterval: 120)  // une version toutes les 2 minutes de travail
        scheduleCompile()
    }

    /// Relit le fichier ouvert s'il a changé sur le disque depuis notre dernière lecture ou écriture.
    func checkDisk() {
        guard let current, isEditingText else { return }
        let url = root.appendingPathComponent(current)
        let date = modificationDate(url)
        guard date != knownDate else { return }
        knownDate = date
        guard let disk = try? String(contentsOf: url, encoding: .utf8), disk != text else { return }
        text = disk
        scheduleCompile()
    }

    /// Au retour dans l'app : nouveaux fichiers, et fichier ouvert modifié par un autre éditeur.
    func reload() {
        refresh()
        if let current, !files.contains(current) { open(nil) }
        checkDisk()
    }

    /// Remet une ancienne version ; la version actuelle part d'abord dans l'historique.
    func restore(_ snapshot: Snapshot) {
        guard let current else { return }
        saveSnapshot(text, root: root, file: current)
        edit(snapshot.text)
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
        outline = documentOutline(main) { [root] in try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
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

    // MARK: Complétion

    func projectSources() -> CompletionSources {
        completionSources(files.filter { ["tex", "bib"].contains(ext($0)) }.compactMap { file in
            (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)).map { (file, $0) }
        })
    }
}
