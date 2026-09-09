import Foundation
import Combine

/// Shared hover/expand state. Driven by AppKit mouse tracking (more reliable than SwiftUI onHover on NSPanel).
@MainActor
final class HoverSession: ObservableObject {
    @Published var isExpanded: Bool = false
    @Published var hovered: ProviderID? = nil

    func expand(hovering id: ProviderID? = nil) {
        if !isExpanded { isExpanded = true }
        if let id { hovered = id }
    }

    func collapse() {
        isExpanded = false
        hovered = nil
    }
}
