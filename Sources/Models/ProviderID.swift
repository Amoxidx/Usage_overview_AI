import Foundation
import SwiftUI

/// The three providers this app tracks.
enum ProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude
    case codex
    case grok

    var id: String { rawValue }

    /// German display name shown in the UI.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .grok:   return "Grok"
        }
    }

    /// Fixed accent colour matching the design frame (not usage-band coloured).
    var accent: Color {
        switch self {
        case .claude: return Color(hex: 0xFF5A2A) // Claude orange
        case .codex:  return Color(hex: 0x5AC8FA) // Codex light blue
        case .grok:   return Color(hex: 0xF5C518) // Grok yellow
        }
    }

    /// Codex stays blue and Grok stays yellow even at high usage (no critical red).
    var usesFixedAccent: Bool { self == .codex || self == .grok }
}

