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
