// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TypingStats",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "TypingStats",
            path: "Sources"
        )
    ]
)
