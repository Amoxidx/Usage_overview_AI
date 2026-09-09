import XCTest
@testable import UsageOverview

final class ClaudeOAuthParsingTests: XCTestCase {
    func testParsesLimitsArraySessionAndWeekly() throws {
        let json = """
        {
          "limits": [
            {"kind": "session", "percent": 9, "resets_at": "2026-09-09T17:09:59.924128+00:00"},
            {"kind": "weekly_all", "percent": 93, "resets_at": "2026-09-09T20:59:59.924162+00:00"},
            {"kind": "weekly_scoped", "percent": 58, "resets_at": "2026-09-09T20:59:59.924501+00:00"}
          ]
        }
        """.data(using: .utf8)!
        let windows = try ClaudeOAuthParser.windows(from: json)
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.09, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.93, accuracy: 0.0001)
        XCTAssertEqual(windows[0].label, DE.currentSession)
        XCTAssertEqual(windows[1].label, DE.allModels)
        XCTAssertEqual(windows[2].label, "Fable")
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNotNil(windows[1].resetsAt)
    }

    func testFallsBackToFiveHourAndSevenDayWhenLimitsEmpty() throws {
        let json = """
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2026-09-09T17:09:59Z"},
          "seven_day": {"utilization": 40, "resets_at": "2026-09-09T20:59:59Z"}
        }
        """.data(using: .utf8)!
        let windows = try ClaudeOAuthParser.windows(from: json)
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.125, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.40, accuracy: 0.0001)
    }

    func testDoesNotOverrideLimitsWithNamedWindows() throws {
        let json = """
        {
          "limits": [
            {"kind": "session", "percent": 9},
            {"kind": "weekly_all", "percent": 93}
          ],
          "five_hour": {"utilization": 50},
          "seven_day": {"utilization": 10}
        }
        """.data(using: .utf8)!
        let windows = try ClaudeOAuthParser.windows(from: json)
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.09, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.93, accuracy: 0.0001)
    }

    func testMissingSessionThrows() {
        let json = Data(#"{"seven_day":{"utilization":40}}"#.utf8)
        XCTAssertThrowsError(try ClaudeOAuthParser.windows(from: json)) { error in
            guard case UsageFetchError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testLoadCredentialReadsNestedAccessToken() throws {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"sk-test-token","expiresAt":9999999999999}}"#.utf8)
        let cred = try ClaudeOAuth.loadCredential(now: Date(timeIntervalSince1970: 1_800_000_000)) {
            blob
        }
        XCTAssertEqual(cred.accessToken, "sk-test-token")
    }

    func testMcpOnlyBlobIsNeedsAuth() {
        let blob = Data(#"{"mcpOAuth":{"x":{}}}"#.utf8)
        XCTAssertThrowsError(try ClaudeOAuth.credential(from: blob, now: Date())) { error in
            guard case UsageFetchError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testSkipsMcpOnlyThenReadsUserItem() throws {
        let mcp = Data(#"{"mcpOAuth":{}}"#.utf8)
        let good = Data(#"{"mcpOAuth":{},"claudeAiOauth":{"accessToken":"sk-ok","expiresAt":9999999999999}}"#.utf8)
        let first = try ClaudeOAuth.credential(from: good, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(first.accessToken, "sk-ok")
        XCTAssertThrowsError(try ClaudeOAuth.credential(from: mcp, now: Date()))
    }

    func testLoadCredentialExpiredThrows() {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"sk-old","expiresAt":1}}"#.utf8)
        XCTAssertThrowsError(try ClaudeOAuth.loadCredential(now: Date(timeIntervalSince1970: 100)) {
            blob
        }) { error in
            guard case UsageFetchError.credentialExpired = error else {
                return XCTFail("expected credentialExpired, got \(error)")
            }
        }
    }
}
