import XCTest
@testable import Notes2LaTeX

final class Tests: XCTestCase {
    func testInsertionPoint() {
        let doc = "A\n\\begin{document}\nx\n\\end{document}"  // corps : 19..21, \end en 21
        XCTAssertEqual(insertionPoint(in: doc, cursor: 20), 19)  // dans le corps : début de la ligne
        XCTAssertEqual(insertionPoint(in: doc, cursor: 0), 21)  // dans le préambule : avant \end
        XCTAssertEqual(insertionPoint(in: doc, cursor: 30), 21)  // après \end
        XCTAssertEqual(insertionPoint(in: "a\nbc", cursor: 3), 2)  // fichier inclus : ligne du curseur
    }

    func testPrediction() {
        let out = "UserWarning: bla\nf: g.png: \\frac{a}{b}\n"
        XCTAssertEqual(prediction(out, file: "f: g.png"), "\\frac{a}{b}")
        XCTAssertNil(prediction("Traceback…", file: "f.png"))
    }

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
}
