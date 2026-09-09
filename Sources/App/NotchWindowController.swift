import AppKit
import SwiftUI
import Combine

/// Hosts the SwiftUI notch in a left-edge NSPanel.
/// Expand/collapse uses a timer mouse poll (works without Accessibility).
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
    private var forceExpandedLocked = false

    /// Visible resting strip width.
    private var collapsedVisualWidth: CGFloat { NotchLayout.pillWidth + 8 }
    /// Panel / hit width when collapsed — wider than the drawn pill so hover is easy.
    private var collapsedHitWidth: CGFloat { max(collapsedVisualWidth, NotchLayout.pillHotZone) }
    private let leaveSlop: CGFloat = 16

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

        if HoverSession.forceExpanded {
            forceExpandedLocked = true
            hover.expand(hovering: .claude)
            applyFrame(expanded: true)
            NSLog("UsageOverview FORCE_EXPANDED locked; frame=%@", NSStringFromRect(panel.frame))
        } else {
            NSLog("UsageOverview rest hit frame=%@", NSStringFromRect(panel.frame))
        }

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
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }

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
        if forceExpandedLocked { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if hover.isExpanded {
            let rect = panel.frame.insetBy(dx: -leaveSlop, dy: -leaveSlop)
            // Also keep open while near the left edge hot band (so collapsing then re-entering is easy).
            let edgeHot = leftEdgeHotZone(on: screen, around: panel.frame)
            if rect.contains(mouse) || edgeHot.contains(mouse) {
                collapseWork?.cancel()
                collapseWork = nil
                if rect.contains(mouse) {
                    updateHoveredProvider(at: mouse, in: panel)
                }
            } else {
                scheduleCollapse()
            }
        } else {
            let hot = leftEdgeHotZone(on: screen, around: panel.frame)
            if hot.contains(mouse) {
                collapseWork?.cancel()
                collapseWork = nil
                hover.expand(hovering: .claude)
                updateHoveredProvider(at: mouse, in: panel)
            }
        }
    }

    /// Generous left-edge band covering the resting panel's Y range (plus slack).
    private func leftEdgeHotZone(on screen: NSScreen?, around panelFrame: NSRect) -> CGRect {
        let visible = screen?.visibleFrame ?? panelFrame
        let y = panelFrame.minY - 40
        let h = panelFrame.height + 80
        return CGRect(
            x: visible.minX,
            y: y,
            width: collapsedHitWidth,
            height: h
        )
    }

    private func updateHoveredProvider(at mouse: CGPoint, in panel: NSPanel) {
        let localY = mouse.y - panel.frame.minY
        let h = panel.frame.height
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
        guard !HoverSession.forceExpanded else { return }
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let panel = self.panel {
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                    ?? NSScreen.main
                let rect = panel.frame.insetBy(dx: -self.leaveSlop, dy: -self.leaveSlop)
                let edge = self.leftEdgeHotZone(on: screen, around: panel.frame)
                if rect.contains(mouse) || edge.contains(mouse) {
                    self.collapseWork = nil
                    return
                }
            }
            self.hover.collapse()
            self.collapseWork = nil
        }
        collapseWork = work
        // Slightly longer so leaving the strip doesn't instantly lose the target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
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
        panel.orderFrontRegardless()
    }

    private func panelFrame(on screen: NSScreen?, expanded: Bool) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Physical left edge of the display (flush) — visibleFrame.minX can sit inset.
        let screenFrame = screen?.frame ?? visible
        let width: CGFloat
        let height: CGFloat
        if expanded {
            width = NotchLayout.bodyDepth + NotchLayout.cardWidth + NotchLayout.tailLength + NotchLayout.tailGap + 40
            height = NotchLayout.shapeLength + 8
        } else {
            width = collapsedHitWidth
            height = NotchLayout.restHitHeight
        }
        let x = screenFrame.minX
        let y = visible.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
