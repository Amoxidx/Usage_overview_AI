import XCTest
import SwiftUI
@testable import UsageOverview

final class ProviderAccentTests: XCTestCase {
    func testGrokAndCodexKeepBrandColourAtHighUsage() {
        XCTAssertTrue(ProviderID.grok.usesFixedAccent, "Grok ring/bar must stay yellow above 70%")
        XCTAssertTrue(ProviderID.codex.usesFixedAccent, "Codex stays blue at high usage")
        XCTAssertFalse(ProviderID.claude.usesFixedAccent, "Claude still follows usage bands")
    }

    func testFixedAccentIgnoresCriticalBand() {
        let grokYellow = ProviderID.grok.accent
        for band: UsageBand in [.ample, .watch, .critical, .exhausted] {
            let color = band.color(accent: grokYellow, fixedAccent: true)
            XCTAssertEqual(color, grokYellow, "\(band) must keep Grok yellow when fixed")
        }
        XCTAssertNotEqual(
            UsageBand.critical.color(accent: grokYellow, fixedAccent: false),
            grokYellow,
            "without the flag, 70%+ would turn critical red — the test must notice a missing flag"
        )
    }
}
