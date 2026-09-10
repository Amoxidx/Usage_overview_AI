import XCTest
import SwiftUI
@testable import UsageOverview

final class NotchMotionTests: XCTestCase {
    func testPanelStaysWiderThanCollapsedHitBand() {
        XCTAssertGreaterThan(NotchLayout.panelWidth, NotchLayout.collapsedHitWidth)
        XCTAssertGreaterThan(NotchLayout.panelHeight, NotchLayout.pillHeight)
        XCTAssertGreaterThan(NotchLayout.shapeLength, NotchLayout.pillHeight)
    }

    func testProgressZeroMatchesHalfStadiumOnPillRect() {
        let rect = CGRect(x: 0, y: 0, width: NotchLayout.pillWidth, height: NotchLayout.pillHeight)
        let morph = MorphingNotch(progress: 0).path(in: rect)
        let stadium = LeftHalfStadium().path(in: rect)

        let inside = CGPoint(x: rect.minX + 1, y: rect.midY)
        XCTAssertTrue(morph.contains(inside))
        XCTAssertTrue(stadium.contains(inside))

        let outsideRight = CGPoint(x: rect.maxX + 4, y: rect.midY)
        XCTAssertFalse(morph.contains(outsideRight))
        XCTAssertFalse(stadium.contains(outsideRight))

        let outsideTopRightCorner = CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5)
        XCTAssertFalse(morph.contains(outsideTopRightCorner))
        XCTAssertFalse(stadium.contains(outsideTopRightCorner))
    }

    func testProgressChangesCoveredArea() {
        let rect = CGRect(x: 0, y: 0, width: NotchLayout.bodyDepth, height: NotchLayout.shapeLength)
        let closed = MorphingNotch(progress: 0).path(in: rect)
        let open = MorphingNotch(progress: 1).path(in: rect)
        XCTAssertFalse(closed.isEmpty)
        XCTAssertFalse(open.isEmpty)
        XCTAssertNotEqual(
            containedCount(closed, in: rect),
            containedCount(open, in: rect),
            "progress must change the silhouette; a constant path is a non-morph"
        )
    }

    func testProgressOneMatchesFlaredNotch() {
        let rect = CGRect(x: 0, y: 0, width: NotchLayout.bodyDepth, height: NotchLayout.shapeLength)
        let morph = MorphingNotch(progress: 1).path(in: rect)
        let flared = SideNotchShape().path(in: rect)
        let body = CGPoint(x: rect.midX, y: rect.midY)
        XCTAssertTrue(morph.contains(body))
        XCTAssertTrue(flared.contains(body))
        XCTAssertEqual(containedCount(morph, in: rect), containedCount(flared, in: rect))
    }

    func testRingCenterYIsCircleCenterNotCellCenter() {
        let expected = NotchLayout.curlRadius + NotchLayout.padTop + NotchLayout.ringDiameter / 2
        XCTAssertEqual(NotchLayout.ringCenterY(for: .claude), expected, accuracy: 0.0001)
        XCTAssertNotEqual(
            NotchLayout.ringCenterY(for: .claude),
            NotchLayout.curlRadius + NotchLayout.padTop + NotchLayout.cellExtent / 2,
            accuracy: 0.0001,
            "caret must aim at the ring, not the midpoint of ring+percent label"
        )
    }

    func testRingCentersStepByCellExtentPlusSpacing() {
        let step = NotchLayout.cellExtent + NotchLayout.cellSpacing
        XCTAssertEqual(
            NotchLayout.ringCenterY(for: .codex) - NotchLayout.ringCenterY(for: .claude),
            step,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NotchLayout.ringCenterY(for: .grok) - NotchLayout.ringCenterY(for: .codex),
            step,
            accuracy: 0.0001
        )
    }

    func testTooltipAlignmentGuidePutsCaretOnRingForAnyCardHeight() {
        // HStack(alignment: .top) places the child's top-guide on the chrome top (y=0).
        // Caret sits at the tooltip's vertical center, so global caret Y = height/2 - guide.
        let heights: [CGFloat] = [60, 100, 140, 180, 240]
        for id in ProviderID.allCases {
            let ring = NotchLayout.ringCenterY(for: id)
            for height in heights {
                let guide = NotchLayout.tooltipTopAlignmentGuide(for: id, tooltipHeight: height)
                let caretY = height / 2 - guide
                XCTAssertEqual(
                    caretY,
                    ring,
                    accuracy: 0.0001,
                    "\(id) caret at height \(height) must hit ring center \(ring), got \(caretY)"
                )
            }
        }
    }

    func testAnimatableDataClampsProgress() {
        var shape = MorphingNotch(progress: 0)
        shape.animatableData = 1.4
        XCTAssertEqual(shape.progress, 1, accuracy: 0.0001)
        shape.animatableData = -0.2
        XCTAssertEqual(shape.progress, 0, accuracy: 0.0001)
    }

    private func containedCount(_ path: Path, in rect: CGRect, step: CGFloat = 6) -> Int {
        var count = 0
        var y = rect.minY
        while y <= rect.maxY {
            var x = rect.minX
            while x <= rect.maxX {
                if path.contains(CGPoint(x: x, y: y)) { count += 1 }
                x += step
            }
            y += step
        }
        return count
    }
}
