// swift-tools-version:5.9
import Foundation
import PackageDescription

let isDev = ProcessInfo.processInfo.environment["DEV_BUILD"] != nil

let package = Package(
    name: "TypingStats",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: isDev ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TypingStats",
            dependencies: isDev ? [] : ["Sparkle"],
            path: "Sources"
        )
    ]
)
