import Foundation
import XCTest
@testable import UsageOverview

final class GrokTokenRefreshTests: XCTestCase {
    private static let entryKey = "https://auth.x.ai::test-user"
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private var temporaryDirectory: URL!
    private var authURL: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokTokenRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        authURL = temporaryDirectory.appendingPathComponent("auth.json")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokRefreshURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        GrokRefreshURLProtocol.handler = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRefreshRotatesAndPersistsTokensWithoutChangingOtherData() async throws {
        try writeAuth(expiresAt: now.addingTimeInterval(-60), permissions: 0o644)
        let originalRoot = try readRoot()
        let recorder = RequestRecorder()
        GrokRefreshURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(
                for: request,
                status: 200,
                json: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":21600}"#
            )
        }

        let credential = try AuthReaders.loadGrok(from: authURL)
        let refreshed = try await AuthReaders.refreshGrok(
            credential: credential,
            authURL: authURL,
            session: session,
            now: now
        )

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(21_600))

        let root = try readRoot()
        let entry = try XCTUnwrap(root[Self.entryKey] as? [String: Any])
        let originalEntry = try XCTUnwrap(originalRoot[Self.entryKey] as? [String: Any])
        XCTAssertEqual(entry["key"] as? String, "new-access")
        XCTAssertEqual(entry["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(entry["email"] as? String, originalEntry["email"] as? String)
        XCTAssertEqual(entry["user_id"] as? String, originalEntry["user_id"] as? String)
        XCTAssertEqual(entry["team_id"] as? String, originalEntry["team_id"] as? String)
        XCTAssertEqual(entry["oidc_issuer"] as? String, originalEntry["oidc_issuer"] as? String)
        XCTAssertEqual(entry["oidc_client_id"] as? String, originalEntry["oidc_client_id"] as? String)
        let unrelated = try XCTUnwrap(root["unrelated"] as? [String: Any])
        let originalUnrelated = try XCTUnwrap(originalRoot["unrelated"] as? [String: Any])
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: unrelated, options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: originalUnrelated, options: .sortedKeys)
        )

        let expiresAt = try XCTUnwrap(AuthReaders.isoDate(entry["expires_at"]))
        XCTAssertGreaterThan(expiresAt, now)
        XCTAssertEqual(
            expiresAt.timeIntervalSince1970,
            now.addingTimeInterval(21_600).timeIntervalSince1970,
            accuracy: 0.001
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://auth.x.ai/oauth2/token")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        XCTAssertEqual(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            "grant_type=refresh_token&refresh_token=old%2Brefresh%2Ftoken%3D&client_id=client%20id%3F"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("client_secret") == true)
    }

    func testRefreshWithoutRotatedTokenKeepsOldRefreshToken() async throws {
        try writeAuth(expiresAt: now.addingTimeInterval(-60))
        GrokRefreshURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 200,
                json: #"{"access_token":"new-access","expires_in":21600}"#
            )
        }

        let credential = try AuthReaders.loadGrok(from: authURL)
        let refreshed = try await AuthReaders.refreshGrok(
            credential: credential,
            authURL: authURL,
            session: session,
            now: now
        )

        XCTAssertEqual(refreshed.refreshToken, "old+refresh/token=")
        let entry = try XCTUnwrap(try readRoot()[Self.entryKey] as? [String: Any])
        XCTAssertEqual(entry["refresh_token"] as? String, "old+refresh/token=")
    }

    func testRefreshAuthFailuresLeaveFileByteIdentical() async throws {
        try writeAuth(expiresAt: now.addingTimeInterval(-60))
        let original = try Data(contentsOf: authURL)

        for status in [400, 401] {
            GrokRefreshURLProtocol.handler = { request in
                Self.response(for: request, status: status, json: #"{"error":"invalid_grant"}"#)
            }
            let credential = try AuthReaders.loadGrok(from: authURL)

            do {
                _ = try await AuthReaders.refreshGrok(
                    credential: credential,
                    authURL: authURL,
                    session: session,
                    now: now
                )
                XCTFail("expected needsAuth for HTTP \(status)")
            } catch let error as UsageFetchError {
                XCTAssertEqual(error, .needsAuth)
            }

            XCTAssertEqual(try Data(contentsOf: authURL), original)
        }
    }

    func testProviderRefreshesWithinWindowButNotWithTenMinutesRemaining() async throws {
        try writeAuth(expiresAt: now.addingTimeInterval(60))
        let nearExpiryRequests = RequestRecorder()
        GrokRefreshURLProtocol.handler = { request in
            nearExpiryRequests.append(request)
            if request.url?.host == "auth.x.ai" {
                return Self.response(
                    for: request,
                    status: 200,
                    json: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":21600}"#
                )
            }
            return Self.response(for: request, status: 200, json: Self.creditsJSON)
        }

        let fixedNow = now
        let nearExpiryProvider = GrokUsageProvider(session: session, authURL: authURL, now: { fixedNow })
        _ = try await nearExpiryProvider.fetch()

        XCTAssertEqual(nearExpiryRequests.requests.map { $0.url?.host }, ["auth.x.ai", "cli-chat-proxy.grok.com"])
        XCTAssertEqual(
            nearExpiryRequests.requests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer new-access"
        )

        try writeAuth(expiresAt: now.addingTimeInterval(600))
        let validRequests = RequestRecorder()
        GrokRefreshURLProtocol.handler = { request in
            validRequests.append(request)
            return Self.response(for: request, status: 200, json: Self.creditsJSON)
        }

        let validProvider = GrokUsageProvider(session: session, authURL: authURL, now: { fixedNow })
        _ = try await validProvider.fetch()

        XCTAssertEqual(validRequests.requests.map { $0.url?.host }, ["cli-chat-proxy.grok.com"])
        XCTAssertEqual(
            validRequests.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer old-access"
        )
    }

    func testBillingAuthFailureRefreshesAndRetriesExactlyOnce() async throws {
        try writeAuth(expiresAt: now.addingTimeInterval(600))
        let recorder = RequestRecorder()
        GrokRefreshURLProtocol.handler = { request in
            let index = recorder.append(request)
            switch index {
            case 0:
                return Self.response(for: request, status: 401, json: "{}")
            case 1:
                return Self.response(
                    for: request,
                    status: 200,
                    json: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":21600}"#
                )
            default:
                return Self.response(for: request, status: 200, json: Self.creditsJSON)
            }
        }

        let fixedNow = now
        let provider = GrokUsageProvider(session: session, authURL: authURL, now: { fixedNow })
        let reading = try await provider.fetch()

        XCTAssertEqual(reading.usedFraction, 0.99)
        XCTAssertEqual(recorder.requests.map { $0.url?.host }, [
            "cli-chat-proxy.grok.com",
            "auth.x.ai",
            "cli-chat-proxy.grok.com"
        ])
        XCTAssertEqual(recorder.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(recorder.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    func testSecondBillingAuthFailureStopsAfterOneRetry() async throws {
        try writeAuth(expiresAt: now.addingTimeInterval(600))
        let recorder = RequestRecorder()
        GrokRefreshURLProtocol.handler = { request in
            let index = recorder.append(request)
            if index == 1 {
                return Self.response(
                    for: request,
                    status: 200,
                    json: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":21600}"#
                )
            }
            return Self.response(for: request, status: index == 0 ? 401 : 403, json: "{}")
        }

        let fixedNow = now
        let provider = GrokUsageProvider(session: session, authURL: authURL, now: { fixedNow })
        do {
            _ = try await provider.fetch()
            XCTFail("expected needsAuth")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .needsAuth)
        }

        XCTAssertEqual(recorder.requests.count, 3)
    }

    private func writeAuth(expiresAt: Date, permissions: Int = 0o600) throws {
        let root: [String: Any] = [
            Self.entryKey: [
                "key": "old-access",
                "refresh_token": "old+refresh/token=",
                "expires_at": isoString(expiresAt),
                "oidc_client_id": "client id?",
                "oidc_issuer": "https://auth.x.ai",
                "email": "grok@example.com",
                "user_id": "user-123",
                "team_id": "team-456"
            ],
            "unrelated": [
                "key": "must-not-change",
                "nested": ["enabled": true],
                "count": 7
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: authURL)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: authURL.path)
    }

    private func readRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: authURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

    private static let creditsJSON = """
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-09-07T20:59:12Z","end":"2026-09-14T20:59:12Z"},\
    "creditUsagePercent":99.0}}
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

private final class GrokRefreshURLProtocol: URLProtocol {
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
