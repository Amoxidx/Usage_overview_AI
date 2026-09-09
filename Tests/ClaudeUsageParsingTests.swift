import XCTest
@testable import UsageOverview

final class ClaudeUsageParsingTests: XCTestCase {
    func testParsesSessionAndWeeklyWindows() throws {
        let text = """
        Current session: 73% used · resets in 51 min
        Current week (all models): 7% used · resets Sep 14 at 5:59am (Europe/Berlin)
        Some prose about what drove usage is ignored.
        """
        let windows = try ClaudeUsageParser.parse(text, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.73, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.07, accuracy: 0.0001)
        XCTAssertEqual(windows[0].label, DE.currentSession)
        XCTAssertEqual(windows[1].label, DE.allModels)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testMissingSessionThrows() {
        let text = "Current week (all models): 4% used · resets tomorrow"
        XCTAssertThrowsError(try ClaudeUsageParser.parse(text)) { error in
            guard case UsageFetchError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }
}
