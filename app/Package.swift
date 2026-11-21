// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notes2LaTeX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Notes2LaTeX"),
        .testTarget(name: "Notes2LaTeXTests", dependencies: ["Notes2LaTeX"]),
    ]
)
