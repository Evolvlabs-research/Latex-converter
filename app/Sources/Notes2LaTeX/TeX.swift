// Outils en ligne de commande : latexmk (compilation), synctex (lien source <-> PDF) ; lecture des photos (Reader.swift).
import AppKit

// Chemin du dépôt figé à la compilation : seulement pour les tests et `swift run` (modèle hors de l'app).
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
func createProject(at url: URL, template: String = newProjectTemplate) -> String? {
    guard !FileManager.default.fileExists(atPath: url.path) else { return "« \(url.lastPathComponent) » existe déjà." }
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try template.write(to: url.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
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

/// Lecteur de formules (Reader.swift) chargé à la première lecture, puis gardé : les lectures suivantes sont rapides.
/// Le modèle est dans Nabla.app (Contents/Resources/Model, copié par build.sh) ; hors de l'app, dans app/Model du dépôt.
actor Predictor {
    static let shared = Predictor()
    private var reader: FormulaReader?

    static var modelDir: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Model")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("vocab.json").path) { return bundled }
        return repo.appendingPathComponent("app/Model")  // swift run, swift test
    }

    func read(_ file: URL) async -> Result<String, PredictError> {
        do {
            if reader == nil { reader = try await FormulaReader.load(from: Self.modelDir) }
            return .success(try reader!.read(file))
        } catch let e as ReadError {
            return .failure(PredictError(e.message))
        } catch {
            return .failure(PredictError(error.localizedDescription))
        }
    }
}

struct PredictError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Rendu d'une formule seule (pour vérifier une lecture avant de l'insérer) ; nil si elle ne compile pas.
func renderFormula(_ latex: String) async -> NSImage? {
    guard let tex = findTool("pdflatex") else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nabla-formule-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let doc = "\\documentclass[border=6pt]{standalone}\n\\usepackage{amsmath,amssymb}\n\\begin{document}\n$\\displaystyle \(latex)$\n\\end{document}\n"
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try doc.write(to: dir.appendingPathComponent("f.tex"), atomically: true, encoding: .utf8)
    } catch { return nil }
    let r = await run(tex, ["-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", "f.tex"], in: dir, timeout: 20)
    guard r.status == 0, let data = try? Data(contentsOf: dir.appendingPathComponent("f.pdf")) else { return nil }
    return NSImage(data: data)
}

// MARK: - Plan du document

struct OutlineItem: Hashable {
    var level: Int  // 0 partie, 1 chapitre, 2 section, 3 sous-section, 4 sous-sous-section
    var title: String
    var file: String
    var line: Int
}

let sectionLevels = ["part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4]

/// Titres dans l'ordre de lecture, en suivant les \input et \include depuis `file`.
func documentOutline(_ file: String, read: (String) -> String?, depth: Int = 0) -> [OutlineItem] {
    guard depth < 10, let text = read(file) else { return [] }
    var items: [OutlineItem] = []
    for (i, raw) in text.components(separatedBy: "\n").enumerated() {
        let line = raw.replacing(#/(^|[^\\])%.*/#) { $0.1 }  // sans les commentaires (mais « \% » reste)
        for m in line.matches(of: #/\\(part|chapter|section|subsection|subsubsection|input|include)\*?(?:\[[^\]]*\])?\{/#) {
            guard let arg = balancedArgument(line[m.range.upperBound...]) else { continue }
            let command = String(m.1)
            if command == "input" || command == "include" {
                let path = ext(arg).isEmpty ? arg + ".tex" : arg
                items += documentOutline(URL(fileURLWithPath: path).standardized.relativePath.replacingOccurrences(of: "./", with: ""),
                                         read: read, depth: depth + 1)
            } else {
                items.append(OutlineItem(level: sectionLevels[command] ?? 2, title: arg, file: file, line: i + 1))
            }
        }
    }
    return items
}

/// Contenu d'un argument jusqu'à l'accolade fermante qui lui correspond (les {} imbriquées sont gardées).
func balancedArgument(_ text: Substring) -> String? {
    var depth = 1
    for i in text.indices {
        if text[i] == "{" { depth += 1 }
        if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[..<i]) } }
    }
    return nil
}

// MARK: - Modèles de projet

struct ProjectTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let main: String
}

let projectTemplates = [
    ProjectTemplate(id: "article", name: "Article", icon: "doc.text", main: newProjectTemplate),
    ProjectTemplate(id: "rapport", name: "Rapport", icon: "book.closed", main: """
    \\documentclass[11pt]{report}
    \\usepackage[T1]{fontenc}
    \\usepackage[french]{babel}
    \\usepackage{amsmath,amssymb,graphicx}
    \\usepackage{hyperref}

    \\title{Titre du rapport}
    \\author{}
    \\date{\\today}

    \\begin{document}
    \\maketitle
    \\tableofcontents

    \\chapter{Introduction}

    \\section{Contexte}
    Texte.

    \\chapter{Conclusion}
    Texte.

    \\end{document}

    """),
    ProjectTemplate(id: "presentation", name: "Présentation", icon: "rectangle.on.rectangle", main: """
    \\documentclass{beamer}
    \\usepackage[T1]{fontenc}
    \\usepackage[french]{babel}
    \\usepackage{amsmath,amssymb}

    \\title{Titre de la présentation}
    \\author{}
    \\date{\\today}

    \\begin{document}

    \\begin{frame}
      \\titlepage
    \\end{frame}

    \\begin{frame}{Première diapositive}
      \\begin{itemize}
        \\item Un point
        \\item Une formule : $\\displaystyle \\sum_{n\\ge 1} \\frac{1}{n^2} = \\frac{\\pi^2}{6}$
      \\end{itemize}
    \\end{frame}

    \\end{document}

    """),
    ProjectTemplate(id: "exercices", name: "Exercices", icon: "list.number", main: """
    \\documentclass[11pt]{article}
    \\usepackage[T1]{fontenc}
    \\usepackage[french]{babel}
    \\usepackage[margin=2.5cm]{geometry}
    \\usepackage{amsmath,amssymb,amsthm,enumitem}

    \\theoremstyle{definition}
    \\newtheorem{exercice}{Exercice}

    \\begin{document}

    \\section*{Feuille d'exercices}

    \\begin{exercice}
    Calculer $\\displaystyle \\int_0^1 x^2\\,dx$.
    \\end{exercice}

    \\begin{exercice}
    \\begin{enumerate}[label=\\alph*)]
      \\item Montrer que la suite $u_n = \\frac{1}{n}$ converge.
      \\item Donner sa limite.
    \\end{enumerate}
    \\end{exercice}

    \\end{document}

    """),
    ProjectTemplate(id: "formule", name: "Formule seule", icon: "function", main: """
    \\documentclass[border=8pt]{standalone}
    \\usepackage{amsmath,amssymb}

    \\begin{document}
    $\\displaystyle
    \\int_0^1 x^2\\,dx = \\frac{1}{3}
    $
    \\end{document}

    """),
]

