import PDFKit
import XCTest
@testable import Notes2LaTeX

final class Tests: XCTestCase {
    func testParseLog() {
        let root = URL(fileURLWithPath: "/p")
        let log = """
        ./chap/a.tex:4: Undefined control sequence.
        LaTeX Warning: Reference `nope' on page 1 undefined on input line 5.
        LaTeX Warning: There were undefined references.
        /opt/tex/x.sty:9: Oops
        """
        XCTAssertEqual(parseLog(log, root: root), [
            LogItem(kind: .error, file: "chap/a.tex", line: 4, message: "Undefined control sequence."),
            LogItem(kind: .warning, line: 5, message: "Reference `nope' on page 1 undefined"),
            LogItem(kind: .warning, message: "There were undefined references"),
            LogItem(kind: .error, line: 9, message: "Oops"),  // fichier hors du projet : pas de lien
        ])
        XCTAssertEqual(parseLog("! Emergency stop.\n", root: root), [LogItem(kind: .error, message: "Emergency stop.")])
    }

    func testRelativePathUnicode() {
        let nfd = URL(fileURLWithPath: "/p/De\u{301}mo"), nfc = "/p/D\u{e9}mo/chap/a.tex"
        XCTAssertEqual(relativePath(nfc, root: nfd), "chap/a.tex")
    }

    func testCommandCompletions() {
        XCTAssertEqual(commandCompletions(prefix: "fr", in: "").first, "frac")
        XCTAssertEqual(commandCompletions(prefix: "in", in: "").prefix(3), ["in", "int", "infty"])  // la commande tapée d'abord
        XCTAssertEqual(commandCompletions(prefix: "R", in: "\\newcommand{\\RR}{\\mathbb{R}}").first, "Rightarrow")
        XCTAssertTrue(commandCompletions(prefix: "R", in: "\\newcommand{\\RR}{\\mathbb{R}}").contains("RR"))  // macro du fichier
        XCTAssertFalse(commandCompletions(prefix: "zz", in: "\\zz").contains("zz"))  // pas la saisie en cours elle-même
        XCTAssertEqual(commandArity["frac"], 2)
        XCTAssertEqual(commandArity["alpha"], 0)
    }

    func testCommandPrefixRange() {
        let text = "x = \\fra y \\\\ab" as NSString
        XCTAssertEqual(commandPrefixRange(text, cursor: 8), NSRange(location: 5, length: 3))  // « \fra|»
        XCTAssertNil(commandPrefixRange(text, cursor: 2))  // pas de « \ » avant
        XCTAssertNil(commandPrefixRange(text, cursor: 5))  // juste après « \ » : rien tapé encore
        XCTAssertEqual(commandPrefixRange("é\\al" as NSString, cursor: 4), NSRange(location: 2, length: 2))
    }

    /// Paquet absent : TeX écrit la cause sur une ligne « ! », puis « Emergency stop » avec le fichier et la ligne.
    func testParseLogMissingPackage() {
        let log = """
        ! LaTeX Error: File `academy.sty' not found.

        Type X to quit or <RETURN> to proceed,
        Enter file name:
        ./main.tex:3: Emergency stop.
        <read *>
        ./main.tex:3:  ==> Fatal error occurred, no output PDF file produced!
        """
        XCTAssertEqual(parseLog(log, root: URL(fileURLWithPath: "/p")), [LogItem(
            kind: .error, file: "main.tex", line: 3,
            message: "Fichier « academy.sty » introuvable : ajoutez-le au projet (+ › Importer des fichiers) ou installez le paquet qui le fournit.")])
    }

    /// PDF sombre : fond presque noir, encre claire, et un aplat bleu qui reste bleu.
    func testInvertedPDF() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ctx = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil))
        ctx.beginPage(mediaBox: &box)  // pas de fond peint, comme un PDF de LaTeX
        ctx.setFillColor(.black); ctx.fill(CGRect(x: 10, y: 10, width: 30, height: 30))
        ctx.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 60, y: 60, width: 30, height: 30))
        ctx.endPage(); ctx.closePDF()

        let page = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(invertedPDF(data as Data)))?.page(at: 0))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        let g = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.current = g
        g.cgContext.setFillColor(.white); g.cgContext.fill(box)  // comme un lecteur : papier blanc sous la page
        page.draw(with: .mediaBox, to: g.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        func rgb(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {  // y depuis le haut
            let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        XCTAssertLessThan(rgb(50, 50).r, 0.2, "le fond doit être sombre")
        XCTAssertGreaterThan(rgb(25, 75).r, 0.8, "l'encre noire doit devenir claire")
        let blue = rgb(75, 25)
        XCTAssertGreaterThan(blue.b, blue.r + 0.2, "le bleu doit rester bleu")
    }

    /// Recolorer le seul paragraphe modifié donne exactement la coloration complète.
    func testIncrementalHighlight() {
        let text = "\\section{A}\n% commentaire\nx $a$ \\frac{1}{2}\n\\begin{align}\nb\n\\end{align}\n"
        let edited = NSTextStorage(string: text)
        highlight(edited)
        let range = NSRange(location: 14, length: 0)  // dans « % commentaire »
        edited.replaceCharacters(in: range, with: "\\textbf{gras} % \\fin")
        highlight(edited, in: (edited.string as NSString).paragraphRange(for: NSRange(location: 14, length: 18)))
        let fresh = NSTextStorage(string: edited.string)
        highlight(fresh)
        XCTAssertTrue(edited.isEqual(to: fresh))
    }

    func testLineNumbers() {
        let starts = lineStarts("a\nbc\n\nd" as NSString)
        XCTAssertEqual(starts, [0, 2, 5, 6])
        XCTAssertEqual(lineNumber(at: 0, in: starts), 1)
        XCTAssertEqual(lineNumber(at: 3, in: starts), 2)
        XCTAssertEqual(lineNumber(at: 5, in: starts), 3)
        XCTAssertEqual(lineNumber(at: 7, in: starts), 4)
    }

    func testEngineFlag() {
        XCTAssertEqual(engineFlag("% !TEX program = XeLaTeX\n\\documentclass{article}"), "-pdfxe")
        XCTAssertEqual(engineFlag("\\documentclass{article}"), "-pdf")
    }

    func testChildURL() {
        let root = URL(fileURLWithPath: "/p")
        XCTAssertEqual(childURL("chap/a.tex", root: root)?.path, "/p/chap/a.tex")
        XCTAssertNil(childURL("../x.tex", root: root))
        XCTAssertNil(childURL("chap/../../x.tex", root: root))
        XCTAssertNil(childURL("/etc/x.tex", root: root))
    }

    /// Vrai projet sur le disque : modèle, \input d'un chapitre, erreur localisée, puis SyncTeX dans les deux sens.
    func testProjectBuildAndSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n2l-\(UUID().uuidString)")
        XCTAssertNil(createProject(at: root))
        XCTAssertNotNil(createProject(at: root), "un dossier existant ne doit pas être réutilisé")
        let out = root.appendingPathComponent("build")

        let clean = await latexmk(root: root, main: "main.tex", outDir: out)
        XCTAssertEqual(clean.log.filter { $0.kind == .error }, [])
        XCTAssertNotNil(clean.pdf)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("chap"), withIntermediateDirectories: true)
        try "Bonjour depuis le chapitre.\n\n\\foo\n".write(to: root.appendingPathComponent("chap/a.tex"), atomically: true, encoding: .utf8)
        let main = root.appendingPathComponent("main.tex")
        try newProjectTemplate.replacingOccurrences(of: "\\end{document}", with: "\\input{chap/a}\n\\end{document}")
            .write(to: main, atomically: true, encoding: .utf8)
        let broken = await latexmk(root: root, main: "main.tex", outDir: out)
        XCTAssertEqual(broken.log.first { $0.kind == .error }, LogItem(kind: .error, file: "chap/a.tex", line: 3, message: "Undefined control sequence."))

        try "Bonjour depuis le chapitre.\n".write(to: root.appendingPathComponent("chap/a.tex"), atomically: true, encoding: .utf8)
        _ = await latexmk(root: root, main: "main.tex", outDir: out)
        let pdf = out.appendingPathComponent("main.pdf")
        let hit = await synctexView(pdf: pdf, file: "chap/a.tex", line: 1, root: root)
        let box = try XCTUnwrap(hit)
        XCTAssertEqual(box.page, 1)
        let back = await synctexEdit(pdf: pdf, page: box.page, x: box.x + 5, y: box.y - 2, root: root)
        XCTAssertEqual(back?.file, "chap/a.tex")
        XCTAssertEqual(back?.line, 1)
    }

    func testCompletionContext() {
        func ctx(_ t: String) -> (CompletionKind, String, String)? {
            let ns = t as NSString
            return completionContext(ns, cursor: ns.length).map { ($0.kind, $0.command, ns.substring(with: $0.range)) }
        }
        XCTAssertEqual(ctx("x \\fr")?.0, .command)
        XCTAssertEqual(ctx("voir \\eqref{eq:")?.2, "eq:")
        XCTAssertEqual(ctx("voir \\eqref{eq:")?.0, .label)
        XCTAssertEqual(ctx("\\cite{knuth, la")?.2, "la")  // après la virgule
        XCTAssertEqual(ctx("\\cite[p.~3]{kn")?.0, .citation)
        XCTAssertEqual(ctx("\\begin{al")?.0, .environment)
        XCTAssertEqual(ctx("\\begin{")?.2, "")
        XCTAssertNil(ctx("\\textbf{gras"))
        XCTAssertNil(ctx("\\ref{a} et"))
    }

    func testCompletionSourcesAndRank() {
        let s = completionSources([
            ("main.tex", "\\begin{equation}\\label{eq:x2}\\end{equation} \\label{sec:int}"),
            ("refs.bib", "@book{knuth, title={T}}\n@Article{ lamport94 ,}\n@comment{pas, une clé}"),
        ])
        XCTAssertEqual(s.labels, ["eq:x2", "sec:int"])
        XCTAssertEqual(s.citations, ["knuth", "lamport94"])
        XCTAssertEqual(s.environments, ["equation"])
        XCTAssertEqual(rank(["sec:int", "eq:x2", "eq:x2"], prefix: "x2"), ["eq:x2"])  // contenu, sans doublon
        XCTAssertEqual(rank(["b", "ab", "a"], prefix: "a"), ["ab", "a", "b"].filter { $0.hasPrefix("a") })
    }

    func testOutline() {
        let files = [
            "main.tex": "\\section{Intégrales de $\\frac{1}{2}$}\n% \\section{commentée}\n\\input{chap/a}\n\\subsection*{Fin}",
            "chap/a.tex": "\\chapter{Suites}",
        ]
        XCTAssertEqual(documentOutline("main.tex") { files[$0] }, [
            OutlineItem(level: 2, title: "Intégrales de $\\frac{1}{2}$", file: "main.tex", line: 1),
            OutlineItem(level: 1, title: "Suites", file: "chap/a.tex", line: 1),
            OutlineItem(level: 3, title: "Fin", file: "main.tex", line: 4),
        ])
    }

    func testHistory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n2l-hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: historyDir(root: root, file: "a.tex").deletingLastPathComponent()) }
        XCTAssertTrue(saveSnapshot("v1", root: root, file: "a.tex"))
        XCTAssertFalse(saveSnapshot("v1", root: root, file: "a.tex"))  // identique : rien de plus
        XCTAssertFalse(saveSnapshot("v2", root: root, file: "a.tex", minInterval: 120))  // trop tôt
        XCTAssertTrue(saveSnapshot("v2", root: root, file: "a.tex"))
        XCTAssertEqual(snapshots(root: root, file: "a.tex").map(\.text), ["v2", "v1"])
    }

    func testTemplatesCompile() async {
        for template in projectTemplates {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("n2l-\(template.id)-\(UUID().uuidString)")
            XCTAssertNil(createProject(at: root, template: template.main))
            let build = await latexmk(root: root, main: "main.tex", outDir: root.appendingPathComponent("build"))
            XCTAssertEqual(build.log.filter { $0.kind == .error }, [], template.name)
            XCTAssertNotNil(build.pdf, template.name)
        }
    }
}
