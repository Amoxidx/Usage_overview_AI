import Foundation

/// Helpers for local CLI auth files. Reads are normally read-only; the sole write is persisting
/// refreshed Grok tokens because xAI rotates refresh tokens and not saving one destroys the login.
enum AuthReaders {

    // MARK: - Codex

    struct CodexCredential: Sendable {
        let accessToken: String
        let accountID: String
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

    static func loadCodex(from authURL: URL = defaultCodexAuthURL(), now: Date = Date()) throws -> CodexCredential {
        struct Auth: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String
            }
            let tokens: Tokens
        }
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(Auth.self, from: data),
              !auth.tokens.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !auth.tokens.account_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageFetchError.needsAuth }

        if let expiry = jwtExp(auth.tokens.access_token), expiry <= now.timeIntervalSince1970 {
            throw UsageFetchError.credentialExpired
        }
        return CodexCredential(accessToken: auth.tokens.access_token, accountID: auth.tokens.account_id)
    }

    static func defaultCodexAuthURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
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
