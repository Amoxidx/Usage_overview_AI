import SwiftUI

/// Left-edge black pill. Expand/collapse is driven by `HoverSession` (AppKit mouse tracking).
struct NotchView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var hover: HoverSession

    var body: some View {
        HStack(alignment: .center, spacing: Design.tooltipGap) {
            pill

            if hover.isExpanded, let id = hover.hovered, let reading = store.readings[id] {
                UsageTooltipView(reading: reading)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hover.hovered)
        .animation(.easeInOut(duration: 0.18), value: hover.isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 0)
    }

    private var pill: some View {
        ZStack(alignment: .topLeading) {
            if hover.isExpanded {
                VStack(spacing: Design.cellSpacing) {
                    ForEach(ProviderID.allCases) { id in
                        let reading = store.readings[id] ?? .empty(id)
                        ProviderRingView(reading: reading, isHovered: hover.hovered == id)
                    }

                    SettingsArcHint()
                        .padding(.top, Design.px(8))
                }
                .padding(.top, Design.padTop)
                .padding(.bottom, Design.padBottom)
                .padding(.horizontal, (Design.bodyDepth - Design.ringDiameter) / 2)
                .transition(.opacity)
            } else {
                Color.clear
                    .frame(width: Design.pillRestDepth + 4,
                           height: Design.px(210))
            }
        }
        .frame(width: hover.isExpanded ? Design.bodyDepth : Design.pillRestDepth + 4,
               alignment: .leading)
        .background(alignment: .leading) {
            LeftEdgePill()
                .fill(Palette.notch)
                .frame(width: hover.isExpanded ? Design.bodyDepth : Design.pillRestDepth,
                       height: hover.isExpanded ? nil : Design.px(210))
                .shadow(color: Palette.shadow, radius: hover.isExpanded ? 12 : 6, x: 3, y: 0)
        }
        .overlay(alignment: .topLeading) {
            if store.isDemo && hover.isExpanded {
                Text(DE.demoBadge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(6)
            }
        }
    }
}

private struct SettingsArcHint: View {
    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: Design.settingsArcSize * 0.55, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.35))
            .frame(width: Design.settingsArcSize, height: Design.settingsArcSize)
            .background(
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
            )
            .accessibilityHidden(true)
    }
}

struct LeftEdgePill: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(Design.cornerRadius, rect.width * 0.45, rect.height * 0.2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
