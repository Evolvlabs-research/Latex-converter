// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notes2LaTeX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Notes2LaTeX"),
        // Fichiers lus par leur chemin dans les tests, pas des ressources.
        .testTarget(name: "Notes2LaTeXTests", dependencies: ["Notes2LaTeX"],
                    exclude: ["Stress", "photo.png", "photo-python.png", "ink-python.png", "reference.json"]),
    ]
)
