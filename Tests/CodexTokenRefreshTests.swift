import Foundation
import XCTest
@testable import UsageOverview

final class CodexTokenRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private var temporaryDirectory: URL!
    private var authURL: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        authURL = temporaryDirectory.appendingPathComponent("auth.json")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexRefreshURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        CodexRefreshURLProtocol.handler = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRefreshRotatesAndPersistsTokensWithoutChangingOtherData() async throws {
        try writeAuth(accessToken: "old-access", permissions: 0o644)
        let originalRoot = try readRoot()
        let recorder = RequestRecorder()
        CodexRefreshURLProtocol.handler = { request in
            recorder.append(request)
            return try Self.tokenResponse(
                for: request,
                access: "new-access",
                refresh: "new-refresh",
                id: "new-id"
            )
        }

        let credential = try AuthReaders.loadCodex(from: authURL)
        let refreshed = try await AuthReaders.refreshCodex(
            credential: credential,
            authURL: authURL,
            session: session,
            now: now
        )

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.accountID, "acct-1")
        XCTAssertNil(refreshed.expiresAt)

        let root = try readRoot()
        let tokens = try XCTUnwrap(root["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, "new-access")
        XCTAssertEqual(tokens["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(tokens["id_token"] as? String, "new-id")
        XCTAssertEqual(tokens["account_id"] as? String, "acct-1")
        XCTAssertEqual(tokens["custom_field"] as? String, "keep-token")
        XCTAssertEqual(root["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(root["OPENAI_API_KEY"] is NSNull)
        XCTAssertEqual(root["unknown_field"] as? String, "keep-root")
        let extra = try XCTUnwrap(root["extra"] as? [String: Any])
        let originalExtra = try XCTUnwrap(originalRoot["extra"] as? [String: Any])
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: extra, options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: originalExtra, options: .sortedKeys)
        )

        let lastRefresh = try XCTUnwrap(root["last_refresh"] as? String)
        XCTAssertNotEqual(lastRefresh, "2020-01-01T00:00:00.000000Z")
        let parsed = try XCTUnwrap(AuthReaders.isoDate(lastRefresh))
        XCTAssertEqual(parsed.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)

        let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertTrue(names.contains("auth.json"))
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["client_id", "grant_type", "refresh_token"])
        XCTAssertEqual(json["client_id"] as? String, "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(json["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(json["refresh_token"] as? String, "old-refresh")
    }

    func testRefreshWithoutRotatedTokenKeepsOldRefreshToken() async throws {
        let bodies = [
            #"{"access_token":"new-access"}"#,
            #"{"access_token":"new-access","refresh_token":""}"#,
            #"{"access_token":"new-access","refresh_token":null}"#
        ]
        for body in bodies {
            try writeAuth(accessToken: "old-access")
            CodexRefreshURLProtocol.handler = { request in
                Self.response(for: request, status: 200, json: body)
            }
            let credential = try AuthReaders.loadCodex(from: authURL)
            let refreshed = try await AuthReaders.refreshCodex(
                credential: credential,
                authURL: authURL,
                session: session,
                now: now
            )

            XCTAssertEqual(refreshed.refreshToken, "old-refresh")
            let tokens = try XCTUnwrap(try readRoot()["tokens"] as? [String: Any])
            XCTAssertEqual(tokens["access_token"] as? String, "new-access")
            XCTAssertEqual(tokens["refresh_token"] as? String, "old-refresh")
            XCTAssertEqual(tokens["id_token"] as? String, "old-id")
        }
    }

    func testPermanentRefreshFailuresLeaveFileByteIdentical() async throws {
        let cases: [(Int, String)] = [
            (400, #"{"error":"invalid_grant"}"#),
            (401, "{}"),
            (400, #"{"error":{"code":"refresh_token_reused"}}"#),
            (400, #"{"error":"refresh_token_expired"}"#),
            (503, #"{"error":"refresh_token_invalidated"}"#)
        ]
        for (status, json) in cases {
            try writeAuth(accessToken: "old-access")
            let original = try Data(contentsOf: authURL)
            CodexRefreshURLProtocol.handler = { request in
                Self.response(for: request, status: status, json: json)
            }
            let credential = try AuthReaders.loadCodex(from: authURL)
            do {
                _ = try await AuthReaders.refreshCodex(
                    credential: credential,
                    authURL: authURL,
                    session: session,
                    now: now
                )
                XCTFail("expected needsAuth for HTTP \(status) \(json)")
            } catch let error as UsageFetchError {
                XCTAssertEqual(error, .needsAuth)
            }
            XCTAssertEqual(try Data(contentsOf: authURL), original)
        }
    }

    func testTransientRefreshFailuresLeaveFileByteIdentical() async throws {
        let cases: [(Int, String, UsageFetchError)] = [
            (500, #"{"error":"server_error"}"#, .badResponse(status: 500)),
            (429, "{}", .rateLimited(retryAfter: 60)),
            (400, #"{"error":"temporarily_unavailable"}"#, .badResponse(status: 400)),
            (403, "{}", .badResponse(status: 403)),
            (200, #"{"refresh_token":"new-refresh","id_token":"new-id"}"#, .badResponse(status: 200))
        ]
        for (status, json, expected) in cases {
            try writeAuth(accessToken: "old-access")
            let original = try Data(contentsOf: authURL)
            CodexRefreshURLProtocol.handler = { request in
                Self.response(for: request, status: status, json: json)
            }
            let credential = try AuthReaders.loadCodex(from: authURL)
            do {
                _ = try await AuthReaders.refreshCodex(
                    credential: credential,
                    authURL: authURL,
                    session: session,
                    now: now
                )
                XCTFail("expected \(expected) for HTTP \(status)")
            } catch let error as UsageFetchError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(try Data(contentsOf: authURL), original)
        }
    }

    func testRefreshWithoutRefreshTokenNeedsAuthAndDoesNotCallNetwork() async throws {
        let absentRefreshTokens: [String?] = [nil, ""]
        for refreshToken in absentRefreshTokens {
            try writeAuth(accessToken: "old-access", refreshToken: refreshToken)
            let original = try Data(contentsOf: authURL)
            let recorder = RequestRecorder()
            CodexRefreshURLProtocol.handler = { request in
                recorder.append(request)
                return Self.response(for: request, status: 500, json: "{}")
            }
            let credential = try AuthReaders.loadCodex(from: authURL)
            XCTAssertNil(credential.refreshToken)
            do {
                _ = try await AuthReaders.refreshCodex(
                    credential: credential,
                    authURL: authURL,
                    session: session,
                    now: now
                )
                XCTFail("expected needsAuth")
            } catch let error as UsageFetchError {
                XCTAssertEqual(error, .needsAuth)
            }
            XCTAssertTrue(recorder.requests.isEmpty)
            XCTAssertEqual(try Data(contentsOf: authURL), original)
        }
    }

    func testLoadCodexReturnsExpiredCredential() throws {
        let exp = now.addingTimeInterval(-60).timeIntervalSince1970
        try writeAuth(accessToken: try unsignedJWT(exp: exp))
        let credential = try AuthReaders.loadCodex(from: authURL)
        XCTAssertEqual(credential.accountID, "acct-1")
        XCTAssertEqual(credential.refreshToken, "old-refresh")
        let expiresAt = try XCTUnwrap(credential.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince1970, exp, accuracy: 0.001)
        XCTAssertLessThan(expiresAt, now)
    }

    func testLoadCodexNeedsAuthWhenTokenOrAccountMissing() throws {
        try writeAuth(accessToken: nil)
        XCTAssertThrowsError(try AuthReaders.loadCodex(from: authURL)) { error in
            XCTAssertEqual(error as? UsageFetchError, .needsAuth)
        }
        try writeAuth(accountID: nil)
        XCTAssertThrowsError(try AuthReaders.loadCodex(from: authURL)) { error in
            XCTAssertEqual(error as? UsageFetchError, .needsAuth)
        }
        try writeAuth(accessToken: "   ", accountID: "   ")
        XCTAssertThrowsError(try AuthReaders.loadCodex(from: authURL)) { error in
            XCTAssertEqual(error as? UsageFetchError, .needsAuth)
        }
    }

    func testRefreshSkipsNetworkWhenDiskTokenWasRenewed() async throws {
        let expired = try unsignedJWT(exp: now.addingTimeInterval(-60).timeIntervalSince1970)
        try writeAuth(accessToken: expired)
        let stale = try AuthReaders.loadCodex(from: authURL)

        let renewed = try unsignedJWT(exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        try writeAuth(
            accessToken: renewed,
            refreshToken: "cli-refresh",
            idToken: "cli-id",
            lastRefresh: "2030-01-01T00:00:00.000000Z"
        )
        let renewedBytes = try Data(contentsOf: authURL)
        let recorder = RequestRecorder()
        CodexRefreshURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(for: request, status: 500, json: "{}")
        }

        let result = try await AuthReaders.refreshCodex(
            credential: stale,
            authURL: authURL,
            session: session,
            now: now
        )

        XCTAssertEqual(result.accessToken, renewed)
        XCTAssertEqual(result.refreshToken, "cli-refresh")
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: authURL), renewedBytes)
    }

    func testPermanentFailureAdoptsNewerValidTokenFromDisk() async throws {
        let expired = try unsignedJWT(exp: now.addingTimeInterval(-60).timeIntervalSince1970)
        try writeAuth(accessToken: expired)
        let stale = try AuthReaders.loadCodex(from: authURL)
        let renewed = try unsignedJWT(exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        let renewedData = try authData(
            accessToken: renewed,
            refreshToken: "cli-refresh",
            idToken: "cli-id",
            lastRefresh: "2030-01-01T00:00:00.000000Z"
        )
        let target = authURL!
        CodexRefreshURLProtocol.handler = { request in
            try renewedData.write(to: target)
            return Self.response(for: request, status: 401, json: "{}")
        }

        let result = try await AuthReaders.refreshCodex(
            credential: stale,
            authURL: authURL,
            session: session,
            now: now
        )

        XCTAssertEqual(result.accessToken, renewed)
        XCTAssertEqual(result.refreshToken, "cli-refresh")
        XCTAssertEqual(try Data(contentsOf: authURL), renewedData)
    }

    func testProviderUsesRefreshedAccessTokenWhenExpired() async throws {
        try await assertProviderRefreshes(remaining: -60)
    }

    func testProviderRefreshesWhenLessThan120SecondsRemain() async throws {
        try await assertProviderRefreshes(remaining: 60)
    }

    func testProviderDoesNotRefreshWhen120SecondsOrMoreRemain() async throws {
        for remaining in [120.0, 600.0] {
            let accessToken = try unsignedJWT(exp: now.addingTimeInterval(remaining).timeIntervalSince1970)
            try writeAuth(accessToken: accessToken)
            let recorder = RequestRecorder()
            CodexRefreshURLProtocol.handler = { request in
                recorder.append(request)
                return Self.response(for: request, status: 200, json: Self.usageJSON)
            }
            let fixedNow = now
            let provider = CodexUsageProvider(session: session, authURL: authURL, now: { fixedNow })
            let reading = try await provider.fetch()

            XCTAssertEqual(try XCTUnwrap(reading.usedFraction), 0.21, accuracy: 0.0001)
            XCTAssertEqual(recorder.requests.map { $0.url?.host }, ["chatgpt.com"])
            XCTAssertEqual(
                recorder.requests.first?.value(forHTTPHeaderField: "Authorization"),
                "Bearer \(accessToken)"
            )
        }
    }

    func testUsageAuthFailureRefreshesAndRetriesExactlyOnce() async throws {
        let accessToken = try unsignedJWT(exp: now.addingTimeInterval(600).timeIntervalSince1970)
        try writeAuth(accessToken: accessToken)
        let recorder = RequestRecorder()
        CodexRefreshURLProtocol.handler = { request in
            let index = recorder.append(request)
            switch index {
            case 0:
                return Self.response(for: request, status: 401, json: "{}")
            case 1:
                return try Self.tokenResponse(for: request, access: "new-access", refresh: "new-refresh", id: "new-id")
            default:
                return Self.response(for: request, status: 200, json: Self.usageJSON)
            }
        }

        let fixedNow = now
        let provider = CodexUsageProvider(session: session, authURL: authURL, now: { fixedNow })
        let reading = try await provider.fetch()

        XCTAssertEqual(try XCTUnwrap(reading.usedFraction), 0.21, accuracy: 0.0001)
        XCTAssertEqual(recorder.requests.map { $0.url?.host }, [
            "chatgpt.com",
            "auth.openai.com",
            "chatgpt.com"
        ])
        XCTAssertEqual(recorder.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(accessToken)")
        XCTAssertEqual(recorder.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(recorder.requests[2].value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
        XCTAssertEqual(recorder.requests.filter { $0.url?.host == "auth.openai.com" }.count, 1)
    }

    func testSecondUsageAuthFailureStopsAfterOneRetry() async throws {
        let accessToken = try unsignedJWT(exp: now.addingTimeInterval(600).timeIntervalSince1970)
        try writeAuth(accessToken: accessToken)
        let recorder = RequestRecorder()
        CodexRefreshURLProtocol.handler = { request in
            let index = recorder.append(request)
            if index == 1 {
                return try Self.tokenResponse(for: request, access: "new-access", refresh: "new-refresh", id: "new-id")
            }
            return Self.response(for: request, status: index == 0 ? 401 : 403, json: "{}")
        }

        let fixedNow = now
        let provider = CodexUsageProvider(session: session, authURL: authURL, now: { fixedNow })
        do {
            _ = try await provider.fetch()
            XCTFail("expected needsAuth")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .needsAuth)
        }
        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertEqual(recorder.requests.filter { $0.url?.host == "auth.openai.com" }.count, 1)
    }

    private func assertProviderRefreshes(remaining: TimeInterval) async throws {
        let accessToken = try unsignedJWT(exp: now.addingTimeInterval(remaining).timeIntervalSince1970)
        try writeAuth(accessToken: accessToken)
        let recorder = RequestRecorder()
        CodexRefreshURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.host == "auth.openai.com" {
                return try Self.tokenResponse(for: request, access: "new-access", refresh: "new-refresh", id: "new-id")
            }
            return Self.response(for: request, status: 200, json: Self.usageJSON)
        }

        let fixedNow = now
        let provider = CodexUsageProvider(session: session, authURL: authURL, now: { fixedNow })
        let reading = try await provider.fetch()

        XCTAssertEqual(try XCTUnwrap(reading.usedFraction), 0.21, accuracy: 0.0001)
        XCTAssertEqual(recorder.requests.map { $0.url?.host }, ["auth.openai.com", "chatgpt.com"])
        XCTAssertEqual(recorder.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(recorder.requests[1].value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
    }

    private func writeAuth(
        accessToken: String? = "old-access",
        accountID: String? = "acct-1",
        refreshToken: String? = "old-refresh",
        idToken: String? = "old-id",
        lastRefresh: String = "2020-01-01T00:00:00.000000Z",
        permissions: Int = 0o600
    ) throws {
        let data = try authData(
            accessToken: accessToken,
            accountID: accountID,
            refreshToken: refreshToken,
            idToken: idToken,
            lastRefresh: lastRefresh
        )
        try data.write(to: authURL)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: authURL.path)
    }

    private func authData(
        accessToken: String?,
        accountID: String? = "acct-1",
        refreshToken: String?,
        idToken: String?,
        lastRefresh: String
    ) throws -> Data {
        var tokens: [String: Any] = ["custom_field": "keep-token"]
        if let accessToken { tokens["access_token"] = accessToken }
        if let accountID { tokens["account_id"] = accountID }
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let idToken { tokens["id_token"] = idToken }
        let root: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "auth_mode": "chatgpt",
            "extra": ["count": 7, "enabled": true],
            "last_refresh": lastRefresh,
            "tokens": tokens,
            "unknown_field": "keep-root"
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func readRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: authURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Unsigned placeholder. The payload is only an `exp` claim, never a real credential.
    private func unsignedJWT(exp: TimeInterval) throws -> String {
        func part(_ object: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return try [
            part(["alg": "none"]),
            part(["exp": exp]),
            "sig"
        ].joined(separator: ".")
    }

    private static func tokenResponse(
        for request: URLRequest,
        access: String,
        refresh: String?,
        id: String?
    ) throws -> (HTTPURLResponse, Data) {
        var object: [String: Any] = ["access_token": access]
        if let refresh { object["refresh_token"] = refresh }
        if let id { object["id_token"] = id }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static let usageJSON = """
    {"rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":18000,"reset_at":1800001000},\
    "secondary_window":{"used_percent":8,"limit_window_seconds":604800,"reset_at":1800600000}}}
    """
}

private final class RequestRecorder: @unchecked Sendable {
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

private final class CodexRefreshURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        do {
            var recordedRequest = request
            recordedRequest.httpBody = Self.body(of: request)
            let (response, data) = try handler(recordedRequest)
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
