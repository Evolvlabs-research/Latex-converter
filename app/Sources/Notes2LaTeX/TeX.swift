// Outils en ligne de commande : latexmk (compilation), synctex (lien source <-> PDF), predict.py (photo -> LaTeX).
import Foundation

// shortcut: chemin du dépôt figé à la compilation ; à remplacer par un réglage si l'app quitte ce dossier.
let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// Les apps lancées depuis le Finder n'ont pas le PATH du terminal : on cherche aux emplacements habituels.
let texDirs = ["/opt/homebrew/bin", "/Library/TeX/texbin", "/usr/local/bin"]

func findTool(_ name: String) -> String? {
    texDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Lance un programme, rend son code de sortie et sa sortie. Arrêté au bout de `timeout` secondes.
func run(_ exe: String, _ args: [String], in dir: URL, timeout: TimeInterval = 120) async -> (status: Int32, out: String) {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (texDirs + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")  // latexmk appelle pdflatex, bibtex…
        env["max_print_line"] = "10000"  // journal TeX sans lignes coupées à 79 caractères
        p.environment = env
        p.standardInput = FileHandle.nullDevice  // TeX ne reste jamais bloqué sur une question
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {  // une boucle infinie en TeX ne bloque pas l'app
            guard p.isRunning else { return }
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-TERM", "-P", "\(pid)"])
            p.terminate()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
}

// MARK: - Compilation

struct LogItem: Hashable {
    enum Kind { case error, warning }
    var kind: Kind
    var file: String? = nil  // relatif au projet ; nil si inconnu ou hors du projet
    var line: Int? = nil
    var message: String
}

struct Build {
    var pdf: Data?
    var log: [LogItem]
}

/// Compile `main` (chemin relatif) depuis la racine du projet ; les fichiers produits vont dans `outDir`.
func latexmk(root: URL, main: String, outDir: URL) async -> Build {
    guard let tool = findTool("latexmk") else {
        return Build(pdf: nil, log: [LogItem(kind: .error, message: "latexmk introuvable. Installer : brew install --cask mactex-no-gui")])
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let name = ((main as NSString).lastPathComponent as NSString).deletingPathExtension
    let source = (try? String(contentsOf: root.appendingPathComponent(main), encoding: .utf8)) ?? ""
    // -norc : un latexmkrc livré avec un projet pourrait lancer n'importe quel programme.
    let r = await run(tool, ["-norc", engineFlag(source), "-interaction=nonstopmode", "-synctex=1",
                             "-file-line-error", "-outdir=\(outDir.path)", main], in: root)
    let logData = (try? Data(contentsOf: outDir.appendingPathComponent(name + ".log"))) ?? Data()
    var log = parseLog(String(decoding: logData, as: UTF8.self), root: root)
    if r.status != 0 && !log.contains(where: { $0.kind == .error }) {
        let last = r.out.split(separator: "\n").last.map(String.init) ?? ""
        log.insert(LogItem(kind: .error, message: "La compilation a échoué. \(last)"), at: 0)
    }
    return Build(pdf: try? Data(contentsOf: outDir.appendingPathComponent(name + ".pdf")), log: log)
}

/// Moteur choisi par le commentaire « % !TEX program = xelatex », comme dans TeXShop et Overleaf.
func engineFlag(_ source: String) -> String {
    let program = source.firstMatch(of: #/%\s*!TEX\s+(?:TS-)?program\s*=\s*(\w+)/#.ignoresCase())?.1.lowercased()
    return ["xelatex": "-pdfxe", "lualatex": "-pdflua"][program ?? ""] ?? "-pdf"
}

/// Erreurs (format -file-line-error : « ./chap/a.tex:4: message ») et avertissements du journal TeX.
func parseLog(_ log: String, root: URL) -> [LogItem] {
    var items: [LogItem] = []
    for line in log.split(separator: "\n") {
        if let m = line.wholeMatch(of: #/(.+?\.\w+):(\d+): (.+)/#) {
            items.append(LogItem(kind: .error, file: relativePath(String(m.1), root: root), line: Int(m.2), message: String(m.3)))
        } else if let m = line.wholeMatch(of: #/(?:LaTeX|Package \w+|Class \w+) Warning: (.+?)(?: on input line (\d+))?\.?/#) {
            items.append(LogItem(kind: .warning, line: m.2.flatMap { Int($0) }, message: String(m.1)))
        }
    }
    if !items.contains(where: { $0.kind == .error }) {  // erreurs sans fichier : arrêt d'urgence…
        items += log.split(separator: "\n").filter { $0.hasPrefix("! ") }
            .map { LogItem(kind: .error, message: String($0.dropFirst(2))) }
    }
    return items
}

/// Chemin relatif au projet (« ./chap/a.tex » ou chemin absolu dedans) ; nil s'il est hors du projet.
func relativePath(_ path: String, root: URL) -> String? {
    // Forme Unicode commune : « é » peut s'écrire en un ou deux caractères selon qui fournit le chemin.
    let base = root.standardized.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping + "/"
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    let full = url.standardized.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
}

/// Fichier du projet à partir d'un nom saisi ; nil s'il sortirait du dossier (« ../ », chemin absolu).
func childURL(_ name: String, root: URL) -> URL? {
    guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
    let url = root.appendingPathComponent(name).standardized
    return url.path.hasPrefix(root.standardized.path + "/") ? url : nil
}

let newProjectTemplate = """
\\documentclass[11pt]{article}
\\usepackage[T1]{fontenc}
\\usepackage[french]{babel}
\\usepackage{amsmath,amssymb}

\\title{Sans titre}
\\author{}
\\date{\\today}

\\begin{document}
\\maketitle

\\section{Introduction}

Une formule :
\\[
\\int_0^1 x^2\\,dx = \\frac{1}{3}
\\]

\\end{document}

"""

/// Crée un dossier de projet avec main.tex ; refuse un dossier qui existe déjà (rien n'est écrasé).
func createProject(at url: URL) -> String? {
    guard !FileManager.default.fileExists(atPath: url.path) else { return "« \(url.lastPathComponent) » existe déjà." }
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try newProjectTemplate.write(to: url.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
    } catch { return error.localizedDescription }
    return nil
}

// MARK: - SyncTeX

/// Valeur de « Clé:valeur » dans la sortie de synctex (premier résultat).
func synctexField(_ out: String, _ key: String) -> String? {
    out.split(separator: "\n").first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)) }
}

/// Point du PDF (page à partir de 1, x et y depuis le haut gauche, en points) -> fichier et ligne.
func synctexEdit(pdf: URL, page: Int, x: Double, y: Double, root: URL) async -> (file: String, line: Int)? {
    guard let tool = findTool("synctex") else { return nil }
    let r = await run(tool, ["edit", "-o", "\(page):\(x):\(y):\(pdf.path)"], in: root)
    guard let input = synctexField(r.out, "Input"), let file = relativePath(input, root: root),
          let line = synctexField(r.out, "Line").flatMap({ Int($0) }) else { return nil }
    return (file, line)
}

/// Ligne d'un fichier -> page (à partir de 1) et boîte : x, ligne de base y depuis le haut, largeur, hauteur.
func synctexView(pdf: URL, file: String, line: Int, root: URL) async -> (page: Int, x: Double, y: Double, width: Double, height: Double)? {
    guard let tool = findTool("synctex") else { return nil }
    let r = await run(tool, ["view", "-i", "\(line):1:\(root.appendingPathComponent(file).path)", "-o", pdf.path], in: root)
    let num = { (key: String) in synctexField(r.out, key).flatMap { Double($0) } }
    guard let page = num("Page"), let h = num("h"), let v = num("v") else { return nil }
    return (Int(page), h, v, num("W") ?? 0, num("H") ?? 0)
}

// MARK: - Photo -> LaTeX

/// predict.py écrit « nom_du_fichier: formule ».
func prediction(_ out: String, file: String) -> String? {
    out.split(separator: "\n").last { $0.hasPrefix(file + ": ") }.map { String($0.dropFirst(file.count + 2)) }
}
