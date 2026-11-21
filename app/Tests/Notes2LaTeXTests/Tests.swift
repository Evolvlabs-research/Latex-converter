import XCTest
@testable import Notes2LaTeX

final class Tests: XCTestCase {
    func testInsertFormula() {
        XCTAssertEqual(insertFormula("x^2", into: "a\n\\end{document}"), "a\n\\[\nx^2\n\\]\n\\end{document}")
        XCTAssertEqual(insertFormula("x", into: "a"), "a\n\\[\nx\n\\]\n")
    }

    func testPrediction() {
        let out = "UserWarning: bla\nf: g.png: \\frac{a}{b}\n"
        XCTAssertEqual(prediction(out, file: "f: g.png"), "\\frac{a}{b}")
        XCTAssertNil(prediction("Traceback…", file: "f.png"))
    }

    func testTexError() {
        XCTAssertEqual(texError("This is pdfTeX\n! Undefined control sequence.\nl.4 \\foo"), "! Undefined control sequence.\nl.4 \\foo")
    }

    func testCompileEndToEnd() async throws {
        let tex = try XCTUnwrap(findTool("pdflatex"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try template.write(to: dir.appendingPathComponent("doc.tex"), atomically: true, encoding: .utf8)
        let r = await Notes2LaTeX.run(tex, ["-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", "doc.tex"], in: dir)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("doc.pdf").path))
    }
}
