import SwiftUI

/// Circular progress ring with provider glyph and percent underneath.
struct ProviderRingView: View {
    let reading: UsageReading
    var isHovered: Bool = false

    private var fraction: Double? { reading.usedFraction }
    private var sweep: CGFloat { CGFloat(min(max(fraction ?? 0, 0), 1)) }

    var body: some View {
        VStack(spacing: Design.ringLabelGap) {
            ZStack {
                // Thick dark track
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: Design.trackStroke)

                // Thinner bright progress stroke centred in the track
                if fraction != nil {
                    Circle()
                        .inset(by: Design.trackStroke / 2)
                        .trim(from: 0, to: sweep)
                        .stroke(
                            reading.id.accent,
                            style: StrokeStyle(lineWidth: Design.progressStroke, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.45), value: sweep)
                }

                ProviderGlyphView(id: reading.id)
                    .opacity(opacityForStatus)
            }
            .frame(width: Design.ringDiameter, height: Design.ringDiameter)
            .drawingGroup()
            .scaleEffect(isHovered ? 1.03 : 1)
            .animation(.easeInOut(duration: 0.2), value: isHovered)

            Text(percentLabel)
                .font(.system(size: Design.fontSize(capPixels: 27), weight: .medium, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
                .frame(height: Design.percentLineHeight)
                .opacity(opacityForStatus)
        }
    }

    private var percentLabel: String {
        if let fraction {
            return "\(PercentFormat.text(for: fraction))%"
        }
        switch reading.status {
        case .needsAuth: return "—"
        case .nothingMetered: return "—"
        case .error: return "!"
        case .stale, .ok: return "—"
        }
    }

    private var opacityForStatus: Double {
        if case .stale = reading.status { return 0.45 }
        return 1
    }
}
