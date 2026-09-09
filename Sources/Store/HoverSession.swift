import Foundation
import Combine

/// Shared hover/expand state. Driven by AppKit mouse tracking (more reliable than SwiftUI onHover on NSPanel).
@MainActor
final class HoverSession: ObservableObject {
    @Published var isExpanded: Bool = false
    @Published var hovered: ProviderID? = nil

    /// QA / screenshot mode: keep the pill expanded with a default tooltip.
    static var forceExpanded: Bool {
        ProcessInfo.processInfo.environment["USAGE_OVERVIEW_FORCE_EXPANDED"] == "1"
    }

    func expand(hovering id: ProviderID? = nil) {
        if !isExpanded { isExpanded = true }
        if let id { hovered = id }
    }

    func collapse() {
        guard !Self.forceExpanded else { return }
        isExpanded = false
        hovered = nil
    }
}
