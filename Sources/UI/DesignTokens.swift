import SwiftUI

/// Layout tokens tuned to the Codenotch design frame (left-edge variant).
/// Ring % labels must sit fully inside the pill — never clipped by the trailing curve.
enum Design {
    /// Points per design-frame pixel (44pt ring / 117px).
    static let scale: CGFloat = 44.0 / 117.0
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    private static let capRatio: CGFloat = 0.714
    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }

    static let ringDiameter = px(117)
    static let trackStroke = px(15.5)
    static let progressStroke = px(8)
    static let glyphSize = px(46)

    static let ringLabelGap = px(12)
    static let percentLineHeight = px(30)
    static let cellSpacing = px(32)

    /// Pill depth (horizontal). Trailing corner radius comes from depth, not height.
    static let bodyDepth = px(186)
    /// Soft Codenotch trailing corners ≈ half depth (never height/2).
    static let pillCornerRadius: CGFloat = bodyDepth * 0.48

    static let padTop = px(40)
    /// Must exceed `pillCornerRadius` — % is centered and the bottom arc reaches center-x.
    static var padBottom: CGFloat { pillCornerRadius + percentLineHeight + px(16) }

    static let pillRestDepth: CGFloat = 10

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

    static var cellHeight: CGFloat {
        ringDiameter + ringLabelGap + percentLineHeight
    }

    static var expandedPillHeight: CGFloat {
        padTop + padBottom + cellHeight * 3 + cellSpacing * 2
    }
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
