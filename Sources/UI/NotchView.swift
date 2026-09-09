import SwiftUI

/// Left-edge black flared notch. Expand/collapse driven by `HoverSession`.
struct NotchView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var hover: HoverSession

    var body: some View {
        HStack(alignment: .top, spacing: NotchLayout.tailGap) {
            pill

            if hover.isExpanded, let id = hover.hovered, let reading = store.readings[id] {
                UsageTooltipView(reading: reading)
                    .padding(.top, tooltipTopPadding(for: id))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hover.hovered)
        .animation(.easeInOut(duration: 0.18), value: hover.isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func tooltipTopPadding(for id: ProviderID) -> CGFloat {
        let index = CGFloat(ProviderID.allCases.firstIndex(of: id) ?? 0)
        let ringCenterY = NotchLayout.curlRadius + NotchLayout.padTop
            + NotchLayout.ringDiameter / 2
            + index * (NotchLayout.cellExtent + NotchLayout.cellSpacing)
        let approxHalf: CGFloat = Design.px(210)
        return max(0, ringCenterY - approxHalf)
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
        // Half a pill split down the middle: flat on the left bezel, round on the right.
        ZStack(alignment: .leading) {
            Color.clear
            LeftHalfStadium()
                .fill(Palette.notch)
                .frame(width: NotchLayout.pillWidth, height: NotchLayout.pillHeight)
                .shadow(color: Palette.shadow, radius: 8, x: 3, y: 0)
                .offset(x: 0) // flush — flat edge sits on screen.frame.minX
        }
        .frame(width: max(NotchLayout.pillWidth + 8, NotchLayout.pillHotZone),
               height: NotchLayout.restHitHeight,
               alignment: .leading)
    }

    private var expandedPill: some View {
        VStack(spacing: NotchLayout.cellSpacing) {
            ForEach(ProviderID.allCases) { id in
                let reading = store.readings[id] ?? .empty(id)
                ProviderRingView(reading: reading, isHovered: hover.hovered == id)
            }
        }
        .padding(.top, NotchLayout.curlRadius + NotchLayout.padTop)
        .padding(.bottom, NotchLayout.curlRadius + NotchLayout.padBottom)
        .padding(.horizontal, NotchLayout.ringMargin)
        .frame(width: NotchLayout.bodyDepth)
        .background {
            SideNotchShape()
                .fill(Palette.notch)
                .shadow(color: Palette.shadow, radius: 14, x: 4, y: 0)
        }
        .clipShape(SideNotchShape())
        .offset(x: 0)
        .overlay(alignment: .topLeading) {
            if store.isDemo && hover.isExpanded && !HoverSession.forceExpanded {
                Text(DE.demoBadge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(8)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .transition(.opacity)
    }
}
