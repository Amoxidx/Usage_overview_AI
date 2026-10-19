import Foundation

/// Helpers for local CLI auth files. Reads are normally read-only. The writes are refreshed Grok
/// and Codex tokens: both issuers rotate refresh tokens, and dropping the new one destroys the login.
enum AuthReaders {

    // MARK: - Codex

    struct CodexCredential: Sendable {
        let accessToken: String
        let accountID: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    static func codexHomes(fileManager: FileManager = .default) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var urls: [URL] = [home.appendingPathComponent(".codex")]
        if let contents = try? fileManager.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) {
            // Include ~/.codex-* profiles (alphabetical). Must not skip hidden files.
            let extras = contents
                .filter { $0.lastPathComponent.hasPrefix(".codex-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            urls.append(contentsOf: extras)
        }
        return urls
    }

    static func loadCodex(from authURL: URL = defaultCodexAuthURL()) throws -> CodexCredential {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = nonEmptyString(tokens["access_token"]),
              let accountID = nonEmptyString(tokens["account_id"])
        else { throw UsageFetchError.needsAuth }

        let expiresAt = jwtExp(accessToken).map { Date(timeIntervalSince1970: $0) }
        return CodexCredential(
            accessToken: accessToken,
            accountID: accountID,
            refreshToken: nonEmptyString(tokens["refresh_token"]),
            expiresAt: expiresAt
        )
    }

    static func defaultCodexAuthURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
    }

    private static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let codexOAuthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let permanentCodexRefreshErrors: Set<String> = [
        "refresh_token_expired",
        "refresh_token_reused",
        "refresh_token_invalidated"
    ]

    /// Exchanges the ChatGPT refresh token and writes the rotated token back.
    /// A parallel `codex` process shares this file. A newer still-valid access token already on
    /// disk is kept, and a permanent failure is dropped when that process published one meanwhile.
    static func refreshCodex(
        credential: CodexCredential,
        authURL: URL = defaultCodexAuthURL(),
        session: URLSession = .shared,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> CodexCredential {
        let onDisk = try? loadCodex(from: authURL)
        if let onDisk, adoptedNewerCodexCredential(onDisk, replacing: credential.accessToken, now: now) {
            return onDisk
        }

        let source = onDisk ?? credential
        guard let refreshToken = source.refreshToken, !refreshToken.isEmpty else {
            throw UsageFetchError.needsAuth
        }

        let payload: [String: String] = [
            "client_id": codexOAuthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw UsageFetchError.badResponse(status: 0)
        }

        var request = URLRequest(url: codexTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if isPermanentCodexRefreshFailure(status: status, data: data) {
            if let recovered = try? loadCodex(from: authURL),
               adoptedNewerCodexCredential(recovered, replacing: source.accessToken, now: now) {
                return recovered
            }
            throw UsageFetchError.needsAuth
        }
        if status == 429 {
            throw UsageFetchError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status) else {
            throw UsageFetchError.badResponse(status: status)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = nonEmptyString(root["access_token"])
        else { throw UsageFetchError.badResponse(status: status) }

        let rotatedRefresh = nonEmptyString(root["refresh_token"])
        let rotatedID = nonEmptyString(root["id_token"])
        try persistCodexTokens(
            accessToken: accessToken,
            refreshToken: rotatedRefresh,
            idToken: rotatedID,
            lastRefresh: codexLastRefreshString(now),
            authURL: authURL,
            fileManager: fileManager
        )

        return CodexCredential(
            accessToken: accessToken,
            accountID: source.accountID,
            refreshToken: rotatedRefresh ?? refreshToken,
            expiresAt: jwtExp(accessToken).map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// `expiresAt == nil` counts as current: the previous loader accepted a token with no `exp`.
    private static func adoptedNewerCodexCredential(
        _ latest: CodexCredential,
        replacing accessToken: String,
        now: Date
    ) -> Bool {
        guard latest.accessToken != accessToken else { return false }
        guard let expiresAt = latest.expiresAt else { return true }
        return expiresAt > now
    }

    private static func isPermanentCodexRefreshFailure(status: Int, data: Data) -> Bool {
        if status == 401 { return true }
        guard let code = codexRefreshErrorCode(from: data) else { return false }
        if status == 400, code == "invalid_grant" { return true }
        return permanentCodexRefreshErrors.contains(code)
    }

    private static func codexRefreshErrorCode(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = root["error"] as? String { return code }
        if let object = root["error"] as? [String: Any] { return object["code"] as? String }
        return nil
    }

    private static func persistCodexTokens(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        lastRefresh: String,
        authURL: URL,
        fileManager: FileManager
    ) throws {
        let original = try Data(contentsOf: authURL)
        guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any]
        else { throw UsageFetchError.needsAuth }

        tokens["access_token"] = accessToken
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let idToken { tokens["id_token"] = idToken }
        root["tokens"] = tokens
        root["last_refresh"] = lastRefresh

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let directory = authURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".auth-refresh-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try updated.write(to: temporaryURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        _ = try fileManager.replaceItemAt(
            authURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }

    private static func codexLastRefreshString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return formatter.string(from: date)
    }

    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let text = any as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    // MARK: - Grok

    struct GrokCredential: Sendable {
        let accessToken: String
        let refreshToken: String?
        let clientID: String
        let expiresAt: Date
        let entryKey: String
    }

    static var grokAuthURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    static let grokTrustedIssuer = "https://auth.x.ai"
    private static let grokTokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    static func loadGrok(from url: URL = grokAuthURL) throws -> GrokCredential {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selected = pickGrokEntryWithKey(from: root),
              let token = selected.entry["key"] as? String, !token.isEmpty,
              let clientID = selected.entry["oidc_client_id"] as? String, !clientID.isEmpty
        else { throw UsageFetchError.needsAuth }

        let expires = isoDate(selected.entry["expires_at"]) ?? Date().addingTimeInterval(30 * 24 * 3600)
        let refreshToken = (selected.entry["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GrokCredential(
            accessToken: token,
            refreshToken: refreshToken,
            clientID: clientID,
            expiresAt: expires,
            entryKey: selected.key
        )
    }

    static func pickGrokEntry(from root: [String: Any]) -> [String: Any]? {
        pickGrokEntryWithKey(from: root)?.entry
    }

    private static func pickGrokEntryWithKey(
        from root: [String: Any]
    ) -> (key: String, entry: [String: Any])? {
        let entries = root.compactMap { key, value -> (key: String, entry: [String: Any])? in
            guard let entry = value as? [String: Any] else { return nil }
            if key.hasPrefix(grokTrustedIssuer) { return (key, entry) }
            if let issuer = entry["oidc_issuer"] as? String, issuer == grokTrustedIssuer {
                return (key, entry)
            }
            return nil
        }
        if let live = entries.first(where: {
            guard let expiry = isoDate($0.entry["expires_at"]) else { return true }
            return expiry > Date()
        }) { return live }
        return entries.first
    }

    static func refreshGrok(
        credential: GrokCredential,
        authURL: URL = grokAuthURL,
        session: URLSession = .shared,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> GrokCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw UsageFetchError.needsAuth
        }

        let fields = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", credential.clientID)
        ]
        guard let body = fields
            .map({ "\($0.0)=\(formEncoded($0.1))" })
            .joined(separator: "&")
            .data(using: .utf8)
        else { throw UsageFetchError.badResponse(status: 0) }

        var request = URLRequest(url: grokTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 || status == 403 {
            throw UsageFetchError.needsAuth
        }
        guard (200..<300).contains(status) else {
            throw UsageFetchError.badResponse(status: status)
        }

        struct RefreshResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: TimeInterval

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }

        guard let refresh = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !refresh.accessToken.isEmpty,
              refresh.expiresIn > 0
        else { throw UsageFetchError.badResponse(status: status) }

        let nextRefreshToken = refresh.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let expiresAt = now.addingTimeInterval(refresh.expiresIn)
        try persistGrokTokens(
            accessToken: refresh.accessToken,
            refreshToken: nextRefreshToken,
            expiresAt: expiresAt,
            entryKey: credential.entryKey,
            authURL: authURL,
            fileManager: fileManager
        )

        return GrokCredential(
            accessToken: refresh.accessToken,
            refreshToken: nextRefreshToken,
            clientID: credential.clientID,
            expiresAt: expiresAt,
            entryKey: credential.entryKey
        )
    }

    private static func persistGrokTokens(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        entryKey: String,
        authURL: URL,
        fileManager: FileManager
    ) throws {
        let original = try Data(contentsOf: authURL)
        guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var entry = root[entryKey] as? [String: Any]
        else { throw UsageFetchError.needsAuth }

        entry["key"] = accessToken
        entry["refresh_token"] = refreshToken
        entry["expires_at"] = grokExpiryString(expiresAt)
        root[entryKey] = entry

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let directory = authURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".auth-refresh-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try updated.write(to: temporaryURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        _ = try fileManager.replaceItemAt(
            authURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }

    private static func formEncoded(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func grokExpiryString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return formatter.string(from: date)
    }

    // MARK: - Helpers

    static func jwtExp(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["exp"] as? Double
    }

    static func isoDate(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
