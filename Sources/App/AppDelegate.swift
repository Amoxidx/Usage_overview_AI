import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = NotchWindowController(store: store)
        controller.show()
        notch = controller
        store.start()

        // Tiny status item so the user can quit without a Dock icon.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.lefthalf.filled",
                                   accessibilityDescription: "UsageOverview")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Aktualisieren", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "UsageOverview beenden", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func refresh() {
        Task { await store.refreshAll() }
    }

    @objc private func quit() {
        store.stop()
        NSApp.terminate(nil)
    }
}
