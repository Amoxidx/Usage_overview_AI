import SwiftUI

/// Dark tooltip with usage bars; caret points left toward the notch (Codenotch LimitWindowRow layout).
struct UsageTooltipView: View {
    let reading: UsageReading

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TooltipCaret()
                .fill(Palette.card)
                .frame(width: NotchLayout.tailLength, height: NotchLayout.tailHeight)

            VStack(alignment: .leading, spacing: NotchLayout.blockSpacing) {
                header
                if reading.windows.isEmpty {
                    VStack(alignment: .leading, spacing: NotchLayout.blockSpacing / 2) {
                        Text(statusMessage)
                            .font(Typography.cardBody)
                            .foregroundStyle(Palette.textSecondary)
                        // Visible onboarding action. The tap itself is caught by
                        // NotchWindowController's mouse monitor — the panel
                        // ignores mouse events so no SwiftUI Button ever fires.
                        if let actionHint {
                            Text(actionHint)
                                .font(Typography.cardBody.weight(.semibold))
                                .foregroundStyle(reading.id.accent)
                        }
                    }
                } else {
                    ForEach(reading.windows) { window in
                        LimitWindowRow(window: window, provider: reading.id)
                    }
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .fill(Palette.card)
                    .shadow(color: Palette.shadow, radius: 22, x: 6, y: 8)
            )
        }
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: NotchLayout.headerGap) {
            ProviderGlyphView(id: reading.id, size: Design.px(28))
            Text(DE.usageTitle(reading.id.displayName))
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            if case .stale = reading.status {
                Text(DE.stale)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.bottom, NotchLayout.headerToBlock - NotchLayout.blockSpacing)
    }

    private var statusMessage: String {
        switch reading.status {
        case .needsAuth: return DE.needsAuth
        case .needsInstall: return DE.needsInstall
        case .nothingMetered: return DE.nothingMetered
        case .error: return DE.error
        case .stale: return DE.stale
        case .ok: return DE.noReading
        }
    }

    private var actionHint: String? {
        switch reading.status {
        case .needsAuth: return DE.clickToLogin
        case .needsInstall: return DE.installHint
        case .ok, .stale, .error, .nothingMetered: return nil
        }
    }
}

/// Label | reset on one line, bar, then "% genutzt" — matches Codenotch LimitWindowRow.
private struct LimitWindowRow: View {
    let window: UsageWindow
    let provider: ProviderID

    private var band: UsageBand { UsageBand.band(for: window.usedFraction ?? 0) }
    private var trackWidth: CGFloat { NotchLayout.cardWidth - 2 * NotchLayout.cardPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.px(20)) {
                Text(window.label)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                if let resets = window.resetsAt {
                    Text(DE.resetCopy(for: resets))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .font(Typography.cardBody)
            .lineLimit(1)

            if let fraction = window.usedFraction {
                GeometryReader { geo in
                    let fill = max(NotchLayout.barHeight,
                                   geo.size.width * CGFloat(min(max(fraction, 0), 1)))
                    let color = band.color(accent: provider.accent, fixedAccent: provider.usesFixedAccent)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.barTrack)
                        Capsule()
                            .fill(color.opacity(0.35))
                            .frame(width: fill)
                            .blur(radius: 1.2)
                        Capsule()
                            .fill(color)
                            .frame(width: fill)
                    }
                }
                .frame(width: trackWidth, height: NotchLayout.barHeight)
                .padding(.top, NotchLayout.labelToBar)

                Text(PercentFormat.usedLabel(for: fraction))
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, NotchLayout.barToUsed)
            }
        }
    }
}

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
