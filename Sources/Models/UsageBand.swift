import SwiftUI

/// Colour a ring or bar takes at a given level of use.
/// Thresholds match Codenotch / the design frame (21% green, 52% yellow, 73% orange).
enum UsageBand: Equatable {
    case ample
    case watch
    case critical
    case exhausted

    static func band(for usedFraction: Double) -> UsageBand {
        switch usedFraction {
        case ..<0.50: return .ample
        case ..<0.70: return .watch
        case ..<1.00: return .critical
        default:      return .exhausted
        }
    }

    func color(accent: Color = Palette.ample, fixedAccent: Bool = false) -> Color {
        if fixedAccent { return accent }
        switch self {
        case .ample:                return accent
        case .watch:                return Palette.watch
        case .critical, .exhausted: return Palette.critical
        }
    }
}
