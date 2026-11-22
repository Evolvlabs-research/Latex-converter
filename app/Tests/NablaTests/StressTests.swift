import AppKit
import XCTest
@testable import Nabla

/// Notations rares ou compliquées (dossier Stress) passées par chaque partie de Nabla qui lit du LaTeX.
final class StressTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Stress")

    /// Copie du projet de stress : les compilations n'écrivent rien dans le dépôt.
    func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n2l-stress-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.fixture, to: root)
        return root
    }

    func read(_ root: URL) -> (String) -> String? {
        { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
    }

    func testCompilesWithRarePackages() async throws {
        let root = try project()
        let build = await latexmk(root: root, main: "main.tex", outDir: root.appendingPathComponent("build"))
        XCTAssertEqual(build.log.filter { $0.kind == .error }, [])
        XCTAssertNotNil(build.pdf)
    }

    func testLuaLaTeXWithUnicodeMath() async throws {
        let root = try project()
        let build = await latexmk(root: root, main: "unicode.tex", outDir: root.appendingPathComponent("build"))
        XCTAssertEqual(build.log.filter { $0.kind == .error }, [])
        XCTAssertNotNil(build.pdf)
    }

    /// Conflit d'extensions (physics redéfinit \qty de siunitx) : l'erreur est située dans le bon fichier, à la bonne ligne.
    func testLogLocatesPackageConflict() async throws {
        let root = try project()
        let main = root.appendingPathComponent("main.tex")
        let text = try String(contentsOf: main, encoding: .utf8).replacingOccurrences(of: "\\SI{9.81}", with: "\\qty{9.81}")
        try text.write(to: main, atomically: true, encoding: .utf8)
        let build = await latexmk(root: root, main: "main.tex", outDir: root.appendingPathComponent("build"))
        let line = text.components(separatedBy: "\n").firstIndex { $0.contains("\\qty{9.81}") }! + 1
        XCTAssertEqual(build.log.first { $0.kind == .error }, LogItem(kind: .error, file: "main.tex", line: line, message: "Undefined control sequence."))
    }

    /// Plan : titres à accolades imbriquées, fichier au nom accentué avec espaces, et rien venant du verbatim.
    func testOutline() throws {
        let root = try project()
        XCTAssertEqual(documentOutline("main.tex", read: read(root)).map { "\($0.level) \($0.file) \($0.title)" }, [
            "2 main.tex Diagrammes $\\mathscr{C}$ et \\texorpdfstring{$\\infty$}{infini}-catégories",
            "2 main.tex Analyse",
            "2 main.tex Physique et chimie",
            "2 chapitres/théorie des groupes.tex Théorie des groupes",
        ])
    }

    func testSyncTeXThroughAccentedFileName() async throws {
        let root = try project()
        let out = root.appendingPathComponent("build")
        _ = await latexmk(root: root, main: "main.tex", outDir: out)
        let pdf = out.appendingPathComponent("main.pdf")
        let file = "chapitres/théorie des groupes.tex"
        let found = await synctexView(pdf: pdf, file: file, line: 2, root: root)
        let hit = try XCTUnwrap(found)
        let back = await synctexEdit(pdf: pdf, page: hit.page, x: hit.x + 5, y: hit.y - 2, root: root)
        XCTAssertEqual(back?.file, file)
        XCTAssertEqual(back?.line, 2)
        // Dans un diagramme tikz-cd aussi.
        let diagram = await synctexView(pdf: pdf, file: "main.tex", line: 29, root: root)
        XCTAssertEqual(diagram?.page, 1)
    }

    func testCompletionOnTrickyInput() throws {
        let root = try project()
        let s = completionSources(["main.tex", "refs.bib", "chapitres/théorie des groupes.tex"].map { ($0, read(root)($0)!) })
        XCTAssertTrue(s.labels.contains("eq:Navier–Stokes_2"))  // tiret unicode dans le label
        XCTAssertEqual(s.citations, ["knuth", "lamport"])
        XCTAssertTrue(s.environments.contains("pNiceMatrix"))
        let typed = "voir~\\cite[th.~2]{knuth, la" as NSString
        let context = try XCTUnwrap(completionContext(typed, cursor: typed.length))
        XCTAssertEqual(context.kind, .citation)
        XCTAssertEqual(typed.substring(with: context.range), "la")
        XCTAssertEqual(rank(s.labels, prefix: "Stokes").first, "eq:Navier–Stokes_2")
    }

    /// « 50\% » n'est pas un commentaire ; « a\\% … » en est un (saut de ligne, puis commentaire).
    func testHighlightPercentSigns() throws {
        let root = try project()
        let storage = NSTextStorage(string: read(root)("main.tex")!)
        highlight(storage)
        let ns = storage.string as NSString
        func isComment(_ needle: String) -> Bool {
            let at = ns.range(of: needle).location
            return (storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
        }
        XCTAssertFalse(isComment("% des cas"))
        XCTAssertTrue(isComment("% ceci est un vrai commentaire"))
    }
}
