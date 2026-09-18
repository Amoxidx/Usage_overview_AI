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

    /// Brand colour for ring and tooltip bar at every usage level.
    var accent: Color {
        switch self {
        case .claude: return Color(hex: 0xFF5A2A) // Claude orange
        case .codex:  return Color(hex: 0x5AC8FA) // Codex light blue
        case .grok:   return Color(hex: 0xF5C518) // Grok yellow
        }
    }

    /// Ring and tooltip-bar colour. Deliberately independent of `usedFraction`:
    /// every provider keeps its brand colour from 0 % to 100 %.
    func ringColor(usedFraction: Double?) -> Color { accent }
}

