import XCTest
@testable import UsageOverview

final class CodexUsageParsingTests: XCTestCase {
    private func windows(_ json: String) throws -> [UsageWindow] {
        try CodexUsageParser.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testBothWindows() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":21,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":8,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.label), [DE.fiveHourLimit, DE.weeklyLimit])
        XCTAssertEqual(result.map(\.usedFraction), [0.21, 0.08])
    }

    func testMonthlyPrimaryNotDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000,
        "reset_after_seconds":1838382,"reset_at":1790585722},"secondary_window":null}}
        """)
        XCTAssertEqual(result.first?.label, DE.monthlyLimit)
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.16, accuracy: 0.0001)
    }

    func testEmptyRateLimitThrows() {
        XCTAssertThrowsError(try windows(#"{"rate_limit":{}}"#)) { error in
            guard case UsageFetchError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }
}
