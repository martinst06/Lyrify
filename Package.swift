// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lyrify",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Lyrify",
            path: "Sources/Lyrify"
        )
    ]
)
