import SwiftUI

// Helper to detect dev builds (set via -DDEV_BUILD compiler flag)
var isDevBuild: Bool {
    #if DEV_BUILD
    return true
    #else
    return false
    #endif
}

@main
struct TypingStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
