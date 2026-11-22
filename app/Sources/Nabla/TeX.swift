// Outils en ligne de commande : latexmk (compilation) et synctex (lien source <-> PDF).
import AppKit

// Les apps lancées depuis le Finder n'ont pas le PATH du terminal : on cherche aux emplacements habituels.
let texDirs = ["/opt/homebrew/bin", "/Library/TeX/texbin", "/usr/local/bin"]

func findTool(_ name: String) -> String? {
    texDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Ce qui manque pour compiler : rien, seulement latexmk (BasicTeX l'omet), ou LaTeX tout entier.
enum TeXSetup { case ready, missingLatexmk, missingTeX }

func texSetup() -> TeXSetup {
    if findTool("latexmk") != nil { return .ready }
    return findTool("pdflatex") != nil ? .missingLatexmk : .missingTeX
}

let mactexURL = URL(string: "https://www.tug.org/mactex/")!

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
        let message = texSetup() == .missingLatexmk
            ? "latexmk manque à votre installation de LaTeX. Dans le Terminal : sudo tlmgr install latexmk"
            : "LaTeX n'est pas installé sur ce Mac. Installez MacTeX (tug.org/mactex), puis recompilez."
        return Build(pdf: nil, log: [LogItem(kind: .error, message: message)])
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
    var cause: String?  // dernière ligne « ! … » : la vraie raison d'un « Emergency stop »
    for line in log.split(separator: "\n") {
        if line.hasPrefix("! ") {
            cause = String(line.dropFirst(2))
        } else if let m = line.wholeMatch(of: #/(.+?\.\w+):(\d+): (.+)/#) {
            var message = String(m.3)
            if message.contains("==> Fatal error") { continue }  // répète l'erreur précédente
            if message == "Emergency stop.", let cause { message = cause }
            items.append(LogItem(kind: .error, file: relativePath(String(m.1), root: root), line: Int(m.2), message: explain(message)))
        } else if let m = line.wholeMatch(of: #/(?:LaTeX|Package \w+|Class \w+) Warning: (.+?)(?: on input line (\d+))?\.?/#) {
            items.append(LogItem(kind: .warning, line: m.2.flatMap { Int($0) }, message: String(m.1)))
        }
    }
    if !items.contains(where: { $0.kind == .error }) {  // erreurs sans fichier ni ligne
        items += log.split(separator: "\n").filter { $0.hasPrefix("! ") && !$0.contains("==> Fatal error") }
            .map { LogItem(kind: .error, message: explain(String($0.dropFirst(2)))) }
    }
    return items
}

/// Message TeX rendu compréhensible quand on sait quoi faire.
func explain(_ message: String) -> String {
    if let m = message.firstMatch(of: #/File `([^']+)' not found/#) {
        return "Fichier « \(m.1) » introuvable : ajoutez-le au projet (+ › Importer des fichiers) ou installez le paquet qui le fournit."
    }
    return message
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
    let path = root.appendingPathComponent(file).path
    // synctex compare le nom octet pour octet avec celui du \input, en général composé (« é » en un caractère).
    // Process décompose les accents de ses arguments et de son environnement : le nom passe par un fichier,
    // que le shell relit tel quel. Forme composée d'abord, puis décomposée.
    for form in [path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping] {
        let argFile = FileManager.default.temporaryDirectory.appendingPathComponent("nabla-synctex-\(UUID().uuidString)")
        guard (try? "\(line):1:\(form)".write(to: argFile, atomically: true, encoding: .utf8)) != nil else { return nil }
        let r = await run("/bin/sh", ["-c", #"exec "$0" view -i "$(cat "$1")" -o "$2""#, tool, argFile.path, pdf.path], in: root)
        try? FileManager.default.removeItem(at: argFile)
        let num = { (key: String) in synctexField(r.out, key).flatMap { Double($0) } }
        if let page = num("Page"), let h = num("h"), let v = num("v") { return (Int(page), h, v, num("W") ?? 0, num("H") ?? 0) }
        if path.allSatisfy(\.isASCII) { break }  // sans accent, les deux formes sont identiques
    }
    return nil
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
    var verbatim: String?  // environnement verbatim en cours : son contenu n'est pas du LaTeX
    for (i, raw) in text.components(separatedBy: "\n").enumerated() {
        if let env = verbatim {
            if raw.contains("\\end{\(env)}") { verbatim = nil }
            continue
        }
        if let m = raw.firstMatch(of: #/\\begin\{(verbatim\*?|Verbatim|lstlisting|minted|comment)\}/#) {
            verbatim = String(m.1)
            continue
        }
        let line = raw
            .replacing(#/\\verb\*?([^A-Za-z\s]).*?\1/#, with: "")  // \verb|\section{…}| n'est pas un titre
            .replacing(#/(^|[^\\])((?:\\\\)*)%.*/#) { $0.1 + $0.2 }  // sans commentaire ; « \% » reste, « \\% » commente
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
    let detail: String  // à quoi il sert, en une ligne sous le nom
    let main: String
}

let projectTemplates = [
    ProjectTemplate(id: "article", name: "Article", icon: "doc.text", detail: "Notes, devoirs, articles", main: newProjectTemplate),
    ProjectTemplate(id: "rapport", name: "Rapport", icon: "book.closed", detail: "Chapitres et sommaire", main: """
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
    ProjectTemplate(id: "presentation", name: "Présentation", icon: "rectangle.on.rectangle", detail: "Diapositives Beamer", main: """
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
    ProjectTemplate(id: "exercices", name: "Exercices", icon: "list.number", detail: "Feuille de TD numérotée", main: """
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
    ProjectTemplate(id: "formule", name: "Formule seule", icon: "function", detail: "Une équation à exporter", main: """
    \\documentclass[border=8pt]{standalone}
    \\usepackage{amsmath,amssymb}

    \\begin{document}
    $\\displaystyle
    \\int_0^1 x^2\\,dx = \\frac{1}{3}
    $
    \\end{document}

    """),
]

