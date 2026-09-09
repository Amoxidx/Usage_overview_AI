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
                .shadow(color: Palette.shadow, radius: hover.isExpanded ? 14 : 6, x: 4, y: 0)
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

/// Flat against the left screen edge; trailing side is a continuous half-capsule
/// (large vertical radius) so the open state matches the Codenotch bezel look.
struct LeftEdgePill: Shape {
    func path(in rect: CGRect) -> Path {
        // Trailing radius = half height → true stadium / capsule end.
        let r = min(rect.width, rect.height / 2)
        var path = Path()
        // Top-left → top before arc
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        // Top trailing quarter-circle into the right side
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        // Right edge
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        // Bottom trailing quarter-circle
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
