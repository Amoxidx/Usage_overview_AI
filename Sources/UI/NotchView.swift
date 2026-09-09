import SwiftUI

/// Left-edge black flared notch. Expand/collapse driven by `HoverSession`.
///
/// One shape morphs from the resting half-stadium into the flared notch. The
/// NSPanel stays at expanded size so this is a transform, not a window jump.
struct NotchView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var hover: HoverSession

    private var expanded: Bool { hover.isExpanded }
    private var progress: CGFloat { expanded ? 1 : 0 }

    var body: some View {
        HStack(alignment: .top, spacing: NotchLayout.tailGap) {
            chrome

            if expanded, let id = hover.hovered, let reading = store.readings[id] {
                UsageTooltipView(reading: reading)
                    .padding(.top, tooltipTopPadding(for: id))
                    .transition(tooltipTransition)
            }
        }
        .animation(expanded ? Motion.expand : Motion.collapse, value: hover.isExpanded)
        .animation(Motion.hover, value: hover.hovered)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    private var tooltipTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: -12))
                .combined(with: .scale(scale: 0.98, anchor: .leading))
                .animation(Motion.expand.delay(Motion.prefersReduced ? 0 : 0.12)),
            removal: .opacity
                .combined(with: .offset(x: -6))
                .animation(Motion.collapse)
        )
    }

    private func tooltipTopPadding(for id: ProviderID) -> CGFloat {
        let index = CGFloat(ProviderID.allCases.firstIndex(of: id) ?? 0)
        let ringCenterY = NotchLayout.curlRadius + NotchLayout.padTop
            + NotchLayout.ringDiameter / 2
            + index * (NotchLayout.cellExtent + NotchLayout.cellSpacing)
        let approxHalf: CGFloat = Design.px(210)
        return max(0, ringCenterY - approxHalf)
    }

    /// Stable outer box (expanded size) so the pill grows up/down/right from the bezel.
    private var chrome: some View {
        ZStack(alignment: .leading) {
            MorphingNotch(progress: progress)
                .fill(Palette.notch)
                .overlay {
                    MorphingNotch(progress: progress)
                        .stroke(Color.white.opacity(0.10 - 0.03 * progress), lineWidth: 0.8)
                }
                .overlay { rings }
                .clipShape(MorphingNotch(progress: progress))
                .shadow(
                    color: Color.black.opacity(0.55),
                    radius: 10 + 6 * progress,
                    x: 4 + progress,
                    y: 0
                )
                .frame(
                    width: expanded ? NotchLayout.bodyDepth : NotchLayout.pillWidth,
                    height: expanded ? NotchLayout.shapeLength : NotchLayout.pillHeight
                )
        }
        .frame(
            width: NotchLayout.bodyDepth,
            height: NotchLayout.shapeLength,
            alignment: .leading
        )
        .overlay(alignment: .topLeading) {
            if store.isDemo && expanded && !HoverSession.forceExpanded {
                Text(DE.demoBadge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    private var rings: some View {
        VStack(spacing: NotchLayout.cellSpacing) {
            ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { index, id in
                let reading = store.readings[id] ?? .empty(id)
                ProviderRingView(reading: reading, isHovered: hover.hovered == id)
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.86)
                    .animation(
                        Motion.content.delay(Motion.contentDelay(for: index, expanding: expanded)),
                        value: expanded
                    )
            }
        }
        .padding(.top, NotchLayout.curlRadius + NotchLayout.padTop)
        .padding(.bottom, NotchLayout.curlRadius + NotchLayout.padBottom)
        .padding(.horizontal, NotchLayout.ringMargin)
        .frame(width: NotchLayout.bodyDepth, height: NotchLayout.shapeLength)
    }
}
