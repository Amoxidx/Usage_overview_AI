import SwiftUI

@main
struct UsageOverviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement / accessory — no main window; notch is an NSPanel.
        Settings {
            EmptyView()
        }
    }
}
