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
        Group {
            if hover.isExpanded {
                expandedPill
            } else {
                collapsedHandle
            }
        }
    }

    private var collapsedHandle: some View {
        Color.clear
            .frame(width: Design.pillRestDepth + 4, height: Design.px(210))
            .background(alignment: .leading) {
                LeftEdgePill()
                    .fill(Palette.notch)
                    .frame(width: Design.pillRestDepth, height: Design.px(210))
                    .shadow(color: Palette.shadow, radius: 6, x: 3, y: 0)
            }
    }

    private var expandedPill: some View {
        VStack(spacing: Design.cellSpacing) {
            ForEach(ProviderID.allCases) { id in
                let reading = store.readings[id] ?? .empty(id)
                ProviderRingView(reading: reading, isHovered: hover.hovered == id)
                    .frame(width: Design.ringDiameter)
            }
        }
        .padding(.top, Design.padTop)
        .padding(.bottom, Design.padBottom)
        .padding(.horizontal, (Design.bodyDepth - Design.ringDiameter) / 2)
        .frame(width: Design.bodyDepth)
        .background {
            LeftEdgePill()
                .fill(Palette.notch)
                .shadow(color: Palette.shadow, radius: 14, x: 4, y: 0)
        }
        // Keep glyphs/% inside the bezel — critical for the bottom (Grok) label.
        .clipShape(LeftEdgePill())
        .overlay(alignment: .topLeading) {
            if store.isDemo {
                Text(DE.demoBadge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(8)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .transition(.opacity)
    }
}

/// Flat on the screen edge; trailing corners use a **depth-based** radius (Codenotch),
/// never `height/2` — a full capsule eats the bottom percent label.
struct LeftEdgePill: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(Design.pillCornerRadius, rect.width * 0.92, rect.height * 0.22)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
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
