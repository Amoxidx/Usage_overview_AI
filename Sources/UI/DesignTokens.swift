import AppKit
import SwiftUI

/// Proportional scale from Codenotch design frame (44pt ring = 117px).
enum Design {
    static let scale: CGFloat = 44.0 / 117.0
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    private static let capRatio: CGFloat = 0.714
    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }
}

/// Layout tokens copied from Codenotch `NotchLayout` (left-edge, three providers).
enum NotchLayout {
    static let sideBodyDepth = Design.px(186)
    static var bodyDepth: CGFloat { sideBodyDepth }

    static let curlRadius   = Design.px(103)
    static let bezelFillet  = Design.px(28)
    static let cornerRadius = Design.px(78.8)
    static let padTop       = Design.px(69.5)
    static let padBottom    = Design.px(50.1)
    static let cellSpacing  = Design.px(83.5)

    /// Resting handle — slightly wider than Codenotch px(26) so it stays visible on dark wallpapers.
    static let pillWidth  = Design.px(30)  // half of prior; left-half stadium
    static let pillHeight = Design.px(158) // half of prior
    /// Invisible hit band around the resting pill (Codenotch-style generous edge).
    static let pillHotZone = Design.px(90)  // hover still wider than visual
    /// Tall transparent panel so you can find the strip without pixel-hunting.
    static let restHitHeight: CGFloat = 320

    static let ringDiameter   = Design.px(117)
    static let trackStroke    = Design.px(16.5)
    static let progressStroke = Design.px(9)
    static let glyphSize      = Design.px(48)
    static let ringLabelGap   = Design.px(26.9)

    static let cardWidth     = Design.px(600)
    static let cardCorner    = Design.px(49.5)
    static let cardPadding   = Design.px(32)
    static let tailLength    = Design.px(75)
    static let tailHeight    = Design.px(87)
    static let tailGap       = Design.px(28)
    static let barHeight     = Design.px(10.5)
    static let headerGap     = Design.px(17)
    static let headerToBlock = Design.px(21)
    static let labelToBar    = Design.px(16.8)
    static let barToUsed     = Design.px(17.8)
    static let blockSpacing  = Design.px(20)
    static let sessionRowGap = Design.px(10)

    static let percentLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 27), weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    static var cellExtent: CGFloat { ringDiameter + ringLabelGap + percentLineHeight }

    /// Body length for 3 provider cells (no flares).
    static var bodyLength: CGFloat {
        padTop + padBottom + 3 * cellExtent + 2 * cellSpacing
    }

    /// Full shape length including top/bottom flares.
    static var shapeLength: CGFloat {
        bodyLength + 2 * curlRadius
    }

    static var ringMargin: CGFloat { (sideBodyDepth - ringDiameter) / 2 }

    /// Resting handle hit width (visual pill plus slack).
    static var collapsedHitWidth: CGFloat { max(pillWidth + 8, pillHotZone) }

    /// Panel stays at expanded size so the shape can morph without a window jump.
    static var panelWidth: CGFloat { bodyDepth + cardWidth + tailLength + tailGap + 40 }
    static var panelHeight: CGFloat { shapeLength + 8 }
}

/// Appear / dismiss springs. Smooth (no bounce) reads cleaner than a snappy overshoot.
enum Motion {
    static var prefersReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Notch growing out of the left-edge pill.
    static var expand: Animation {
        prefersReduced ? .easeOut(duration: 0.01) : .smooth(duration: 0.38)
    }

    /// Notch collapsing back into the pill — same curve, shorter so dismiss feels decisive.
    static var collapse: Animation {
        prefersReduced ? .easeOut(duration: 0.01) : .smooth(duration: 0.26)
    }

    /// Tooltip following the hovered ring.
    static var hover: Animation {
        prefersReduced ? .easeOut(duration: 0.01) : .smooth(duration: 0.22)
    }

    /// Rings fading in after the chrome has started to open.
    static var content: Animation {
        prefersReduced ? .easeOut(duration: 0.01) : .smooth(duration: 0.30)
    }

    static func contentDelay(for index: Int, expanding: Bool) -> Double {
        guard expanding, !prefersReduced else { return 0 }
        return Double(index) * 0.045
    }
}

enum Palette {
    static let notch         = Color.black
    static let card          = Color.black
    static let ringTrack     = Color(hex: 0x3A3A3A)
    static let barTrack      = Color(hex: 0x333333)
    static let ample         = Color(hex: 0x00FF88)
    static let watch         = Color(hex: 0xF2FF00)
    static let critical      = Color(hex: 0xFF3F00)
    static let textPrimary   = Color.white
    static let textSecondary = Color(hex: 0x808080)
    static let shadow        = Color.black.opacity(0.45)
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
