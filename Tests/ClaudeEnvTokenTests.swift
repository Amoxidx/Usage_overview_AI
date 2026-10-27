import Foundation
import XCTest
@testable import UsageOverview

final class ClaudeEnvTokenTests: XCTestCase {
    private static let usageJSON = #"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#
    private var session: URLSession!

    override func setUpWithError() throws {
        ClaudeEnvURLProtocol.handler = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeEnvURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        ClaudeEnvURLProtocol.handler = nil
    }

    func testEnvTokenIsSentWhenKeychainIsEmpty() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let loaded = try XCTUnwrap(
            ClaudeOAuth.loadCredentialFromEnvironment(now: now) { "  env-token \n" }
        )
        XCTAssertEqual(loaded.accessToken, "env-token")
        XCTAssertEqual(loaded.expiresAt, now.addingTimeInterval(3600))

        let recorder = ClaudeRequestRecorder()
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(
                for: request,
                status: 200,
                json: #"{"five_hour":{"utilization":99}}"#,
                headers: Self.bothRateLimitHeaders
            )
        }

        let provider = makeProvider(
            loadEnvironment: { loaded },
            loadKeychain: {
                XCTFail("keychain must stay unread when the env token succeeds")
                throw UsageFetchError.needsAuth
            }
        )
        let reading = try await provider.fetch()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        assertMessagesProbe(request, token: "env-token")
        XCTAssertEqual(reading.id, .claude)
        XCTAssertEqual(reading.status, .ok)
        XCTAssertEqual(reading.headlineID, "weekly_all")
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(reading.windows[0].label, DE.currentSession)
        XCTAssertEqual(reading.windows[1].label, DE.allModels)
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[1].usedFraction ?? -1, 0.91, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_112_600))
        XCTAssertEqual(reading.windows[1].resetsAt, Date(timeIntervalSince1970: 1_793_221_200))
        XCTAssertEqual(reading.windows[0].duration ?? -1, TimeInterval(5 * 3600), accuracy: 0.001)
        XCTAssertEqual(reading.windows[1].duration ?? -1, TimeInterval(7 * 86400), accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction ?? -1, 0.91, accuracy: 0.0001)
    }

    func testEnvToken401FallsBackToKeychainCredential() async throws {
        for status in [401, 403] {
            let recorder = ClaudeRequestRecorder()
            ClaudeEnvURLProtocol.handler = { request in
                let index = recorder.append(request)
                if index == 0 {
                    return Self.response(for: request, status: status, json: "{}")
                }
                return Self.response(for: request, status: 200, json: Self.usageJSON)
            }

            let provider = makeProvider(
                loadEnvironment: { Self.credential("env-token") },
                loadKeychain: { Self.credential("keychain-token") }
            )
            let reading = try await provider.fetch()

            XCTAssertEqual(recorder.requests.count, 2, "HTTP \(status)")
            assertMessagesProbe(recorder.requests[0], token: "env-token")
            XCTAssertEqual(
                recorder.requests[1].value(forHTTPHeaderField: "Authorization"),
                "Bearer keychain-token",
                "HTTP \(status)"
            )
            XCTAssertEqual(recorder.requests[1].url, ClaudeOAuth.usageURL, "HTTP \(status)")
            assertUsageWindows(reading)
        }
    }

    func testBlankEnvironmentTokenIsNotUsed() async throws {
        for blank in ["", " ", "\n", "\t", "  \n\t "] {
            XCTAssertNil(ClaudeOAuth.loadCredentialFromEnvironment { blank })
        }
        XCTAssertNil(ClaudeOAuth.readEnvironmentToken(environment: [:]) { " \n\t " })

        let recorder = ClaudeRequestRecorder()
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(for: request, status: 200, json: Self.usageJSON)
        }
        let provider = makeProvider(
            loadEnvironment: { ClaudeOAuth.loadCredentialFromEnvironment { "   \n" } },
            loadKeychain: { Self.credential("keychain-token") }
        )
        let reading = try await provider.fetch()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.url, ClaudeOAuth.usageURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer keychain-token")
        assertUsageWindows(reading)
    }

    func testMessagesResponseWithoutSessionUtilizationThrows() async throws {
        let recorder = ClaudeRequestRecorder()
        let keychainReads = CallCounter()
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(for: request, status: 200, json: #"{"five_hour":{"utilization":99}}"#)
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                keychainReads.increment()
                return Self.credential("keychain-token")
            }
        )
        do {
            _ = try await provider.fetch()
            XCTFail("expected badResponse when the session utilization header is missing")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .badResponse(status: 200))
        }
        XCTAssertEqual(keychainReads.count, 0)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.url, ClaudeOAuth.messagesURL)
    }

    func testMessagesResponseWithOnlySessionHeaderOmitsWeekly() async throws {
        ClaudeEnvURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 200,
                json: #"{"seven_day":{"utilization":99}}"#,
                headers: [
                    "Anthropic-Ratelimit-Unified-5h-Utilization": "0.2",
                    "Anthropic-Ratelimit-Unified-5h-Reset": "1793112600"
                ]
            )
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                XCTFail("keychain must stay unread")
                throw UsageFetchError.needsAuth
            }
        )
        let reading = try await provider.fetch()
        XCTAssertEqual(reading.windows.map(\.id), ["session"])
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_112_600))
        XCTAssertEqual(reading.windows[0].label, DE.currentSession)
    }

    func testMessagesRateLimitWithoutUtilizationThrows() async throws {
        let recorder = ClaudeRequestRecorder()
        let keychainReads = CallCounter()
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(
                for: request,
                status: 429,
                json: #"{"error":"rate_limited"}"#,
                headers: ["Retry-After": "3550"]
            )
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                keychainReads.increment()
                return Self.credential("keychain-token")
            }
        )
        do {
            _ = try await provider.fetch()
            XCTFail("expected badResponse")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .badResponse(status: 429))
        }
        XCTAssertEqual(keychainReads.count, 0)
        XCTAssertEqual(recorder.requests.count, 2)
        assertMessagesProbe(recorder.requests[0], token: "env-token")
        XCTAssertEqual(recorder.requests[1].url, ClaudeOAuth.modelsURL)
        XCTAssertEqual(recorder.requests[1].httpMethod, "GET")
    }

    func testMessagesRateLimitWithUtilizationReturnsWindows() async throws {
        let keychainReads = CallCounter()
        ClaudeEnvURLProtocol.handler = { request in
            var headers = Self.bothRateLimitHeaders
            headers["Retry-After"] = "3550"
            return Self.response(
                for: request,
                status: 429,
                json: #"{"five_hour":{"utilization":99}}"#,
                headers: headers
            )
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                keychainReads.increment()
                return Self.credential("keychain-token")
            }
        )
        let reading = try await provider.fetch()
        XCTAssertEqual(keychainReads.count, 0)
        XCTAssertEqual(reading.status, .ok)
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[1].usedFraction ?? -1, 0.91, accuracy: 0.0001)
        XCTAssertEqual(reading.headlineID, "weekly_all")
        XCTAssertEqual(reading.usedFraction ?? -1, 0.91, accuracy: 0.0001)
    }

    func testProcessEnvironmentTokenSkipsShell() {
        var shellReads = 0
        let token = ClaudeOAuth.readEnvironmentToken(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "  from-env  "]
        ) {
            shellReads += 1
            return "from-shell"
        }
        XCTAssertEqual(token, "from-env")
        XCTAssertEqual(shellReads, 0)
    }

    func testBlankProcessEnvironmentReadsShell() {
        let token = ClaudeOAuth.readEnvironmentToken(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": " \t "]
        ) {
            "  from-shell \n"
        }
        XCTAssertEqual(token, "from-shell")

        let missing = ClaudeOAuth.readEnvironmentToken(environment: [:]) { "from-shell" }
        XCTAssertEqual(missing, "from-shell")
    }

    func testCLIQuotaTextSkipsEnvAndKeychain() async throws {
        ClaudeEnvURLProtocol.handler = { request in
            XCTFail("CLI quota text must not hit the usage endpoint")
            return Self.response(for: request, status: 500, json: "{}")
        }
        let provider = makeProvider(
            runCLI: {
                """
                Current session: 10% used
                Current week (all models): 20% used
                """
            },
            loadEnvironment: {
                XCTFail("env token must not be read when the CLI prints quotas")
                return nil
            },
            loadKeychain: {
                XCTFail("keychain must not be read when the CLI prints quotas")
                throw UsageFetchError.needsAuth
            }
        )
        let reading = try await provider.fetch()
        XCTAssertEqual(reading.status, .ok)
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.10, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[1].usedFraction ?? -1, 0.20, accuracy: 0.0001)
    }

    func testRateLimitedHonorsRetryAfterSeconds() async throws {
        let recorder = ClaudeRequestRecorder()
        try await assertUsageEndpointRateLimit(recorder: recorder, header: "3569", expected: 3569)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.url, ClaudeOAuth.usageURL)
    }

    func testRateLimitedWithoutUsableRetryAfterUsesSixtySeconds() async throws {
        try await assertUsageEndpointRateLimit(header: nil, expected: 60)
        try await assertUsageEndpointRateLimit(header: "soon", expected: 60)
        try await assertUsageEndpointRateLimit(header: "3569.5", expected: 3569.5)
    }

    func testBadResponseDoesNotFallBackToKeychain() async throws {
        let recorder = ClaudeRequestRecorder()
        let keychainReads = CallCounter()
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(for: request, status: 500, json: "{}")
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                keychainReads.increment()
                return Self.credential("keychain-token")
            }
        )
        do {
            _ = try await provider.fetch()
            XCTFail("expected badResponse")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .badResponse(status: 500))
        }
        XCTAssertEqual(keychainReads.count, 0)
        XCTAssertEqual(recorder.requests.count, 2)
        assertMessagesProbe(recorder.requests[0], token: "env-token")
        XCTAssertEqual(recorder.requests[1].url, ClaudeOAuth.modelsURL)
        XCTAssertEqual(recorder.requests[1].httpMethod, "GET")
    }

    func testMissingDefaultModelSearchesAndRemembersCandidate() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let recorder = ClaudeRequestRecorder()
        let firstCandidate = "claude-haiku-5-5"
        let remembered = "claude-haiku-4-5-20251001"
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            if request.url == ClaudeOAuth.modelsURL {
                let json = """
                {"data":[{"id":"claude-haiku-4-5"},{"id":"\(firstCandidate)"},{"id":"\(remembered)"},{"id":"claude-sonnet-5-5"}]}
                """
                return Self.response(for: request, status: 200, json: json)
            }
            switch Self.model(in: request) {
            case ClaudeOAuth.defaultProbeModel:
                return Self.response(for: request, status: 404, json: #"{"type":"error","error":{"type":"not_found_error"}}"#)
            case firstCandidate:
                return Self.response(for: request, status: 429, json: #"{"error":"rate_limited"}"#, headers: ["Retry-After": "30"])
            case remembered:
                return Self.response(for: request, status: 200, json: "{}", headers: Self.bothRateLimitHeaders)
            default:
                XCTFail("unexpected model \(Self.model(in: request) ?? "nil")")
                return Self.response(for: request, status: 500, json: "{}")
            }
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                XCTFail("keychain must stay unread")
                throw UsageFetchError.needsAuth
            },
            envHeaderCacheInterval: 300,
            now: { clock.now() }
        )

        let first = try await provider.fetch()
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(first.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(first.windows[0].usedFraction ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(first.fetchedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(recorder.requests.count, 4)
        assertMessagesProbe(recorder.requests[0], token: "env-token")
        XCTAssertEqual(recorder.requests[1].url, ClaudeOAuth.modelsURL)
        XCTAssertEqual(recorder.requests[1].httpMethod, "GET")
        XCTAssertEqual(recorder.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer env-token")
        XCTAssertEqual(recorder.requests[1].value(forHTTPHeaderField: "anthropic-beta"), ClaudeOAuth.betaHeader)
        XCTAssertEqual(recorder.requests[1].value(forHTTPHeaderField: "anthropic-version"), ClaudeOAuth.messagesAPIVersion)
        XCTAssertNil(recorder.requests[1].httpBody)
        assertMessagesProbe(recorder.requests[2], token: "env-token", model: firstCandidate)
        assertMessagesProbe(recorder.requests[3], token: "env-token", model: remembered)
        XCTAssertFalse(recorder.requests.contains { Self.model(in: $0) == "claude-sonnet-5-5" })

        clock.advance(by: 100)
        let second = try await provider.fetch()
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(recorder.requests.count, 4)

        clock.advance(by: 201)
        let third = try await provider.fetch()
        XCTAssertEqual(recorder.requests.count, 5)
        assertMessagesProbe(recorder.requests[4], token: "env-token", model: remembered)
        XCTAssertEqual(recorder.requests.filter { $0.url == ClaudeOAuth.modelsURL }.count, 1)
        XCTAssertEqual(third.fetchedAt, clock.now())
        XCTAssertEqual(third.windows[1].usedFraction ?? -1, 0.91, accuracy: 0.0001)
    }

    func testRateLimitWithoutHeaderTriesHaikuBeforeOtherModels() async throws {
        let recorder = ClaudeRequestRecorder()
        let haiku = "claude-haiku-4-5-20251001"
        let sonnet = "claude-sonnet-5-5"
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            if request.url == ClaudeOAuth.modelsURL {
                let json = """
                {"data":[{"id":"\(ClaudeOAuth.defaultProbeModel)"},{"id":"\(sonnet)"},{"id":"\(haiku)"},{"id":"claude-sonnet-4-5-20250929","display_name":"ignored"}]}
                """
                return Self.response(for: request, status: 200, json: json)
            }
            if Self.model(in: request) == haiku {
                return Self.response(for: request, status: 200, json: "{}", headers: Self.bothRateLimitHeaders)
            }
            return Self.response(
                for: request,
                status: 429,
                json: #"{"error":"rate_limited"}"#,
                headers: ["Retry-After": "3550"]
            )
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                XCTFail("keychain must stay unread")
                throw UsageFetchError.needsAuth
            }
        )
        let reading = try await provider.fetch()
        XCTAssertEqual(reading.status, .ok)
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(
            recorder.requests.compactMap { Self.model(in: $0) },
            [ClaudeOAuth.defaultProbeModel, haiku]
        )
        XCTAssertEqual(recorder.requests.map(\.url), [
            ClaudeOAuth.messagesURL,
            ClaudeOAuth.modelsURL,
            ClaudeOAuth.messagesURL
        ])
        XCTAssertFalse(recorder.requests.contains { Self.model(in: $0) == sonnet })
    }

    func testExhaustedModelSearchThrowsAndSkipsListForAnHour() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let recorder = ClaudeRequestRecorder()
        let keychainReads = CallCounter()
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            if request.url == ClaudeOAuth.modelsURL {
                return Self.response(
                    for: request,
                    status: 200,
                    json: #"{"data":[{"id":"claude-haiku-5-5"},{"id":"claude-sonnet-5-5"}]}"#
                )
            }
            return Self.response(
                for: request,
                status: 429,
                json: #"{"error":"rate_limited"}"#,
                headers: ["Retry-After": "3550"]
            )
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                keychainReads.increment()
                return Self.credential("keychain-token")
            },
            envHeaderCacheInterval: 0,
            now: { clock.now() }
        )
        do {
            _ = try await provider.fetch()
            XCTFail("expected badResponse")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .badResponse(status: 429))
        }
        XCTAssertEqual(keychainReads.count, 0)
        XCTAssertEqual(
            recorder.requests.compactMap { Self.model(in: $0) },
            [ClaudeOAuth.defaultProbeModel, "claude-haiku-5-5", "claude-sonnet-5-5"]
        )
        XCTAssertEqual(recorder.requests.filter { $0.url == ClaudeOAuth.modelsURL }.count, 1)

        let countAfterFirst = recorder.requests.count
        clock.advance(by: 100)
        do {
            _ = try await provider.fetch()
            XCTFail("expected badResponse within the hour")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .badResponse(status: 429))
        }
        XCTAssertEqual(recorder.requests.count, countAfterFirst + 1)
        assertMessagesProbe(try XCTUnwrap(recorder.requests.last), token: "env-token")
        XCTAssertEqual(recorder.requests.filter { $0.url == ClaudeOAuth.modelsURL }.count, 1)
        XCTAssertEqual(keychainReads.count, 0)
    }

    func testModelSearchStopsAfterFourExtraProbes() async throws {
        let recorder = ClaudeRequestRecorder()
        let extras = (1...6).map { "claude-haiku-extra-\($0)" }
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            if request.url == ClaudeOAuth.modelsURL {
                let rows = extras.map { id in #"{"id":"\#(id)"}"# }.joined(separator: ",")
                return Self.response(for: request, status: 200, json: #"{"data":[\#(rows)]}"#)
            }
            return Self.response(for: request, status: 429, json: #"{"error":"rate_limited"}"#)
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                XCTFail("keychain must stay unread")
                throw UsageFetchError.needsAuth
            }
        )
        do {
            _ = try await provider.fetch()
            XCTFail("expected badResponse")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .badResponse(status: 429))
        }
        XCTAssertEqual(
            recorder.requests.compactMap { Self.model(in: $0) },
            [ClaudeOAuth.defaultProbeModel] + Array(extras.prefix(4))
        )
        XCTAssertEqual(recorder.requests.filter { $0.url == ClaudeOAuth.modelsURL }.count, 1)
    }

    func testEnvHeaderResultIsReusedForTheCacheInterval() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualClock(start)
        let recorder = ClaudeRequestRecorder()
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(for: request, status: 200, json: "{}", headers: Self.bothRateLimitHeaders)
        }
        let provider = makeProvider(
            loadEnvironment: { Self.credential("env-token") },
            loadKeychain: {
                XCTFail("keychain must stay unread")
                throw UsageFetchError.needsAuth
            },
            envHeaderCacheInterval: 300,
            now: { clock.now() }
        )
        let first = try await provider.fetch()
        clock.advance(by: 100)
        let second = try await provider.fetch()
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(first.fetchedAt, start)
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(second.windows[1].usedFraction ?? -1, 0.91, accuracy: 0.0001)

        clock.advance(by: 201)
        let third = try await provider.fetch()
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(third.fetchedAt, start.addingTimeInterval(301))
        assertMessagesProbe(recorder.requests[0], token: "env-token")
        assertMessagesProbe(recorder.requests[1], token: "env-token")
    }

    func testModelsEndpointAuthFailureFallsBackToKeychain() async throws {
        for status in [401, 403] {
            let recorder = ClaudeRequestRecorder()
            ClaudeEnvURLProtocol.handler = { request in
                recorder.append(request)
                if request.url == ClaudeOAuth.modelsURL {
                    return Self.response(for: request, status: status, json: "{}")
                }
                if recorder.requests.count == 1 {
                    return Self.response(for: request, status: 404, json: #"{"type":"error"}"#)
                }
                return Self.response(for: request, status: 200, json: Self.usageJSON)
            }
            let provider = makeProvider(
                loadEnvironment: { Self.credential("env-token") },
                loadKeychain: { Self.credential("keychain-token") }
            )
            let reading = try await provider.fetch()
            XCTAssertEqual(recorder.requests.count, 3, "HTTP \(status)")
            assertMessagesProbe(recorder.requests[0], token: "env-token")
            XCTAssertEqual(recorder.requests[1].url, ClaudeOAuth.modelsURL, "HTTP \(status)")
            XCTAssertEqual(
                recorder.requests[1].value(forHTTPHeaderField: "Authorization"),
                "Bearer env-token",
                "HTTP \(status)"
            )
            XCTAssertEqual(recorder.requests[2].url, ClaudeOAuth.usageURL, "HTTP \(status)")
            XCTAssertEqual(
                recorder.requests[2].value(forHTTPHeaderField: "Authorization"),
                "Bearer keychain-token",
                "HTTP \(status)"
            )
            assertUsageWindows(reading)
        }
    }

    private func assertUsageEndpointRateLimit(
        recorder: ClaudeRequestRecorder = ClaudeRequestRecorder(),
        header: String?,
        expected: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        ClaudeEnvURLProtocol.handler = { request in
            recorder.append(request)
            var headers = ["Content-Type": "application/json"]
            if let header {
                headers["Retry-After"] = header
            }
            return Self.response(for: request, status: 429, json: "{}", headers: headers)
        }
        do {
            _ = try await ClaudeOAuth.fetchWindows(
                session: session,
                credential: Self.credential("usage-token")
            )
            XCTFail("expected rateLimited", file: file, line: line)
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .rateLimited(retryAfter: expected), file: file, line: line)
        }
        let request = try XCTUnwrap(recorder.requests.first, file: file, line: line)
        XCTAssertEqual(recorder.requests.count, 1, file: file, line: line)
        XCTAssertEqual(request.url, ClaudeOAuth.usageURL, file: file, line: line)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer usage-token",
            file: file,
            line: line
        )
    }

    private func makeProvider(
        runCLI: @escaping @Sendable () throws -> String = { throw UsageFetchError.needsAuth },
        loadEnvironment: @escaping @Sendable () -> ClaudeOAuth.Credential?,
        loadKeychain: @escaping @Sendable () throws -> ClaudeOAuth.Credential,
        envHeaderCacheInterval: TimeInterval = 0,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ClaudeUsageProvider {
        ClaudeUsageProvider(
            session: session,
            runCLI: runCLI,
            loadEnvironment: loadEnvironment,
            loadKeychain: loadKeychain,
            envHeaderCacheInterval: envHeaderCacheInterval,
            now: now
        )
    }

    private static func credential(_ token: String) -> ClaudeOAuth.Credential {
        ClaudeOAuth.Credential(accessToken: token, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private static let bothRateLimitHeaders = [
        "anthropic-ratelimit-unified-5h-utilization": "0.2",
        "anthropic-ratelimit-unified-5h-reset": "1793112600",
        "anthropic-ratelimit-unified-7d-utilization": "0.91",
        "anthropic-ratelimit-unified-7d-reset": "1793221200"
    ]

    private func assertMessagesProbe(
        _ request: URLRequest,
        token: String,
        model: String = ClaudeOAuth.defaultProbeModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.httpMethod, "POST", file: file, line: line)
        XCTAssertEqual(request.url, ClaudeOAuth.messagesURL, file: file, line: line)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(token)",
            file: file,
            line: line
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", file: file, line: line)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "content-type"),
            "application/json",
            file: file,
            line: line
        )
        XCTAssertEqual(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            #"{"model":"\#(model)","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}"#,
            file: file,
            line: line
        )
    }

    private static func model(in request: URLRequest) -> String? {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object["model"] as? String
    }

    private func assertUsageWindows(
        _ reading: UsageReading,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reading.id, .claude, file: file, line: line)
        XCTAssertEqual(reading.status, .ok, file: file, line: line)
        XCTAssertEqual(reading.headlineID, "weekly_all", file: file, line: line)
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly_all"], file: file, line: line)
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.12, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(reading.windows[1].usedFraction ?? -1, 0.34, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(reading.usedFraction ?? -1, 0.34, accuracy: 0.0001, file: file, line: line)
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        json: String,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? ClaudeOAuth.usageURL,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, Data(json.utf8))
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ClaudeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func append(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
        return storage.count - 1
    }
}

private final class ClaudeEnvURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            var recorded = request
            recorded.httpBody = Self.body(of: request)
            let (response, data) = try handler(recorded)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }

    override func stopLoading() {}
}
