import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene keeps app running as menubar-only app
        // Login window is managed by AppDelegate
        Settings {
            EmptyView()
        }
    }
}
