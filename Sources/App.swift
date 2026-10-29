import Cocoa

// Helper to detect dev builds (set via -DDEV_BUILD compiler flag)
var isDevBuild: Bool {
    #if DEV_BUILD
    return true
    #else
    return false
    #endif
}

// Plain AppKit entry point. A SwiftUI `App` needs at least one Scene, and its placeholder
// `Settings` scene would pop up an empty "Settings" window whenever the last real window closed.
@main
enum TypingStatsMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
