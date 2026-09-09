import SwiftUI

/// Circular progress ring with provider glyph and percent underneath (Codenotch ProviderRing).
struct ProviderRingView: View {
    let reading: UsageReading
    var isHovered: Bool = false

    private var fraction: Double? { reading.usedFraction }
    private var sweep: CGFloat { CGFloat(min(max(fraction ?? 0, 0), 1)) }
    private var band: UsageBand { UsageBand.band(for: fraction ?? 0) }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)

                if fraction != nil {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: sweep)
                        .stroke(
                            band.color(accent: reading.id.accent, fixedAccent: reading.id.usesFixedAccent),
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.45), value: sweep)
                }

                ProviderGlyphView(id: reading.id)
                    .opacity(opacityForStatus)
            }
            .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
            .drawingGroup()
            .scaleEffect(isHovered ? 1.03 : 1)
            .animation(.easeInOut(duration: 0.2), value: isHovered)

            Text(percentLabel)
                .font(Typography.percent)
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
                .frame(height: NotchLayout.percentLineHeight)
                .opacity(opacityForStatus)
        }
        .frame(height: NotchLayout.cellExtent)
    }

    private var percentLabel: String {
        if let fraction {
            return "\(PercentFormat.text(for: fraction))%"
        }
        switch reading.status {
        case .needsAuth, .nothingMetered, .stale, .ok: return "—"
        case .error: return "!"
        }
    }

    private var opacityForStatus: Double {
        if case .stale = reading.status { return 0.45 }
        return 1
    }
}
