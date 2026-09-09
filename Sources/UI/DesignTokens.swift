import SwiftUI

/// Layout and colour tokens tuned to the Codenotch design frame.
enum Design {
    /// Points per design-frame pixel (44pt ring / 117px).
    static let scale: CGFloat = 44.0 / 117.0
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    /// Cap-height → point size for SF Pro (matches Codenotch Typography).
    private static let capRatio: CGFloat = 0.714
    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }

    static let ringDiameter = px(117)
    /// Thick dark track; thinner bright progress sits centred in the track.
    static let trackStroke = px(15.5)
    static let progressStroke = px(8)
    static let glyphSize = px(46)
    /// Tight gap under ring → percent (reference look).
    static let ringLabelGap = px(14)
    static let percentLineHeight = px(32)
    static let cellSpacing = px(28)
    static let padTop = px(36)
    static let padBottom = px(28)
    static let bodyDepth = px(186)
    static let cornerRadius = px(78.8)
    static let bezelFillet = px(28)

    static let pillRestDepth: CGFloat = 10
    static let hoverRevealPadding: CGFloat = 4

    static let cardWidth = px(560)
    static let cardPadding = px(32)
    static let cardCorner = px(40)
    static let barHeight = px(12)
    static let barCorner = px(6)
    static let headerGap = px(14)
    static let headerToBlock = px(20)
    static let labelToBar = px(12)
    static let barToUsed = px(10)
    static let blockSpacing = px(18)
    static let tailLength = px(22)
    static let tailHeight = px(36)
    static let tooltipGap: CGFloat = 10

    /// Decorative settings arc at bottom of expanded pill (non-functional).
    static let settingsArcSize = px(28)
}

enum Palette {
    static let notch = Color.black
    static let card = Color(hex: 0x121212).opacity(0.96)
    static let ringTrack = Color(hex: 0x303030)
    static let barTrack = Color(hex: 0x2D2D2D)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0x808080)
    static let shadow = Color.black.opacity(0.5)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
