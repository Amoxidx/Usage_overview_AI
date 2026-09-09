import AppKit
import SwiftUI
import Combine

/// Hosts the SwiftUI notch in a left-edge NSPanel.
/// Expand/collapse uses a global mouse monitor so it always dismisses when the cursor leaves.
@MainActor
final class NotchWindowController {
    private var panel: NotchPanel?
    private let store: UsageStore
    private let hover = HoverSession()
    private var screenObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var hoverCancellable: AnyCancellable?
    private var collapseWork: DispatchWorkItem?
    private var pollTimer: Timer?

    /// Collapsed strip width (points).
    private let collapsedWidth: CGFloat = 16
    /// Extra padding around hit-test when expanded.
    private let leaveSlop: CGFloat = 8

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = panelFrame(on: screen, expanded: false)
        let panel = NotchPanel(contentRect: frame)
        let root = NotchView(store: store, hover: hover)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        hoverCancellable = hover.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.applyFrame(expanded: expanded)
            }

        installMouseMonitor()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyFrame(expanded: self.hover.isExpanded)
            }
        }
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private func installMouseMonitor() {
        // Timer polling works without Accessibility permission (unlike global monitors).
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }

        // Best-effort global monitor (needs Accessibility); fine if it fails/nil.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor in self?.handleMouseMoved() }
            return event
        }
    }

    private func handleMouseMoved() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation // bottom-left origin, global

        if hover.isExpanded {
            // Stay open while inside the panel (plus slop). Collapse shortly after leaving.
            let rect = panel.frame.insetBy(dx: -leaveSlop, dy: -leaveSlop)
            if rect.contains(mouse) {
                collapseWork?.cancel()
                collapseWork = nil
                updateHoveredProvider(at: mouse, in: panel)
            } else {
                scheduleCollapse()
            }
        } else {
            // Open when cursor enters the thin left-edge hot zone overlapping the panel's Y range.
            let hot = CGRect(
                x: panel.frame.minX,
                y: panel.frame.minY,
                width: collapsedWidth + 14,
                height: panel.frame.height
            )
            if hot.contains(mouse) {
                collapseWork?.cancel()
                collapseWork = nil
                withAnimationIfNeeded {
                    hover.expand(hovering: .claude) // default until refined
                }
                updateHoveredProvider(at: mouse, in: panel)
            }
        }
    }

    private func updateHoveredProvider(at mouse: CGPoint, in panel: NSPanel) {
        // Map mouse Y into the three ring bands (top → bottom: claude, codex, grok).
        let localY = mouse.y - panel.frame.minY
        let h = panel.frame.height
        // SwiftUI is top-down; AppKit Y is bottom-up.
        let fromTop = h - localY
        let providers = ProviderID.allCases
        let band = h / CGFloat(providers.count)
        var index = Int(fromTop / max(band, 1))
        index = min(max(index, 0), providers.count - 1)
        let id = providers[index]
        if hover.hovered != id {
            hover.hovered = id
        }
    }

    private func scheduleCollapse() {
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-check: only collapse if still outside.
            if let panel = self.panel {
                let mouse = NSEvent.mouseLocation
                let rect = panel.frame.insetBy(dx: -self.leaveSlop, dy: -self.leaveSlop)
                if rect.contains(mouse) { return }
            }
            self.hover.collapse()
            self.collapseWork = nil
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func withAnimationIfNeeded(_ body: () -> Void) {
        body()
    }

    private func applyFrame(expanded: Bool) {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = panelFrame(on: screen, expanded: expanded)
        panel.setFrame(frame, display: true, animate: false)
        panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        if let hosting = panel.contentView as? NSHostingView<NotchView> {
            hosting.rootView = NotchView(store: store, hover: hover)
        }
    }

    private func panelFrame(on screen: NSScreen?, expanded: Bool) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat
        if expanded {
            width = Design.bodyDepth + Design.cardWidth + Design.tailLength + Design.tooltipGap + 40
        } else {
            width = collapsedWidth
        }
        let height = Design.padTop + Design.padBottom
            + Design.ringDiameter * 3
            + Design.ringLabelGap * 3
            + Design.percentLineHeight * 3
            + Design.cellSpacing * 2
            + Design.settingsArcSize
            + Design.px(24)
            + 40
        let x = visible.minX
        let y = visible.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
