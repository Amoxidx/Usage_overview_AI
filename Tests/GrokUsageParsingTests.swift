import XCTest
@testable import UsageOverview

final class GrokUsageParsingTests: XCTestCase {
    private let credits = """
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-09-05T08:21:18.802818+00:00",\
    "end":"2026-09-12T08:21:18.802818+00:00"},\
    "creditUsagePercent":52.0,\
    "productUsage":[{"product":"GrokBuild","usagePercent":52.0}],\
    "billingPeriodStart":"2026-09-05T08:21:18.802818+00:00",\
    "billingPeriodEnd":"2026-09-12T08:21:18.802818+00:00"}}
    """

    func testCreditsPercentage() throws {
        let windows = try GrokUsageParser.windows(creditsJSON: credits)
        let credits = try XCTUnwrap(windows.first { $0.id == "credits" })
        XCTAssertEqual(credits.usedFraction ?? -1, 0.52, accuracy: 0.0001)
        XCTAssertEqual(credits.label, "Grok Build")
        XCTAssertEqual(credits.duration, 7 * 86400)
    }

    func testEmptyConfigFails() {
        XCTAssertThrowsError(try GrokUsageParser.windows(creditsJSON: #"{"config":{}}"#)) { error in
            guard case UsageFetchError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testWeeklyPoolWithoutPercentIsZero() throws {
        let weeklyOnly = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-09-07T20:59:12+00:00",\
        "end":"2026-09-14T20:59:12+00:00"}}}
        """
        let windows = try GrokUsageParser.windows(creditsJSON: weeklyOnly)
        XCTAssertEqual(windows.first?.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(windows.first?.label, DE.weeklyLimit)
    }

    func testHumanize() {
        XCTAssertEqual(GrokUsageParser.humanize("GrokBuild"), "Grok Build")
    }
}
