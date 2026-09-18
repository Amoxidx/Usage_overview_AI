import XCTest
import SwiftUI
@testable import UsageOverview

final class ProviderAccentTests: XCTestCase {
    func testRingColorEqualsAccentForEveryProviderAndUsage() {
        let fractions: [Double?] = [nil, 0.0, 0.21, 0.49, 0.5, 0.55, 0.7, 0.85, 0.99, 1.0, 1.4]
        for provider in ProviderID.allCases {
            for fraction in fractions {
                XCTAssertEqual(
                    provider.ringColor(usedFraction: fraction),
                    provider.accent,
                    "\(provider.displayName) at \(String(describing: fraction)) must equal its accent"
                )
            }
        }
    }

    func testClaudeAccentIs0xFF5A2A() {
        XCTAssertEqual(
            ProviderID.claude.accent,
            Color(hex: 0xFF5A2A),
            "Claude brand colour is pinned at 0xFF5A2A so the ring cannot silently recast"
        )
    }

    func testCodexAccentIs0x5AC8FA() {
        XCTAssertEqual(
            ProviderID.codex.accent,
            Color(hex: 0x5AC8FA),
            "Codex brand colour is pinned at 0x5AC8FA so the ring cannot silently recast"
        )
    }

    func testGrokAccentIs0xF5C518() {
        XCTAssertEqual(
            ProviderID.grok.accent,
            Color(hex: 0xF5C518),
            "Grok brand colour is pinned at 0xF5C518 so the ring cannot silently recast"
        )
    }
}
