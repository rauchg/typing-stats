// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TypingStats",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TypingStats",
            dependencies: ["Sparkle"],
            path: "Sources"
        )
    ]
)
