// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nabla",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Nabla"),
        // Projet de stress lu par son chemin dans les tests, pas une ressource.
        .testTarget(name: "NablaTests", dependencies: ["Nabla"], exclude: ["Stress"]),
    ]
)
