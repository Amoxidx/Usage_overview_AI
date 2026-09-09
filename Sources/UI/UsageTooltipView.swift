import SwiftUI

/// Dark tooltip with usage bars and reset times; caret points left toward the notch.
struct UsageTooltipView: View {
    let reading: UsageReading

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TooltipCaret()
                .fill(Palette.card)
                .frame(width: Design.tailLength, height: Design.tailHeight)

            VStack(alignment: .leading, spacing: Design.blockSpacing) {
                header
                if reading.windows.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: Design.fontSize(capPixels: 18)))
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(reading.windows) { window in
                        WindowRow(window: window, accent: reading.id.accent)
                    }
                }
            }
            .padding(Design.cardPadding)
            .frame(width: Design.cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.cardCorner, style: .continuous)
                    .fill(Palette.card)
                    .shadow(color: Palette.shadow, radius: 22, x: 6, y: 8)
            )
        }
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: Design.headerGap) {
            ProviderGlyphView(id: reading.id, size: Design.px(28))
            Text(DE.usageTitle(reading.id.displayName))
                .font(.system(size: Design.fontSize(capPixels: 26), weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            if case .stale = reading.status {
                Text(DE.stale)
                    .font(.system(size: Design.fontSize(capPixels: 16)))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.bottom, Design.headerToBlock - Design.blockSpacing)
    }

    private var statusMessage: String {
        switch reading.status {
        case .needsAuth: return DE.needsAuth
        case .nothingMetered: return DE.nothingMetered
        case .error: return DE.error
        case .stale: return DE.stale
        case .ok: return DE.noReading
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Design.labelToBar) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: Design.fontSize(capPixels: 18), weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if let resets = window.resetsAt {
                    Text(DE.resetCopy(for: resets))
                        .font(.system(size: Design.fontSize(capPixels: 16)))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.barTrack)
                    if let fraction = window.usedFraction {
                        Capsule()
                            .fill(accent)
                            .frame(width: max(Design.barHeight,
                                              geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                            .animation(.easeInOut(duration: 0.35), value: fraction)
                    }
                }
            }
            .frame(height: Design.barHeight)

            Text(summary)
                .font(.system(size: Design.fontSize(capPixels: 18)))
                .foregroundStyle(Palette.textPrimary.opacity(0.92))
                .padding(.top, Design.barToUsed - Design.labelToBar)
        }
    }

    private var summary: String {
        if let fraction = window.usedFraction {
            return PercentFormat.usedLabel(for: fraction)
        }
        return DE.noReading
    }
}

/// Triangular caret pointing left (toward the left-edge notch).
private struct TooltipCaret: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tip = CGPoint(x: rect.minX, y: rect.midY)
        let top = CGPoint(x: rect.maxX, y: rect.minY)
        let bottom = CGPoint(x: rect.maxX, y: rect.maxY)
        path.move(to: top)
        path.addCurve(to: tip,
                      control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25),
                      control2: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY - rect.height * 0.12))
        path.addCurve(to: bottom,
                      control1: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY + rect.height * 0.12),
                      control2: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25))
        path.closeSubpath()
        return path
    }
}
