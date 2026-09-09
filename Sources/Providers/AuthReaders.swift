import Foundation

/// Read-only helpers for local CLI auth files. Never write credentials.
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
        let expiresAt: Date
    }

    static var grokAuthURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    static let grokTrustedIssuer = "https://auth.x.ai"

    static func loadGrok(from url: URL = grokAuthURL) throws -> GrokCredential {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = pickGrokEntry(from: root),
              let token = entry["key"] as? String, !token.isEmpty
        else { throw UsageFetchError.needsAuth }

        let expires = isoDate(entry["expires_at"]) ?? Date().addingTimeInterval(30 * 24 * 3600)
        return GrokCredential(accessToken: token, expiresAt: expires)
    }

    static func pickGrokEntry(from root: [String: Any]) -> [String: Any]? {
        let entries = root.compactMap { key, value -> [String: Any]? in
            guard let entry = value as? [String: Any] else { return nil }
            if key.hasPrefix(grokTrustedIssuer) { return entry }
            if let issuer = entry["oidc_issuer"] as? String, issuer == grokTrustedIssuer { return entry }
            return nil
        }
        if let live = entries.first(where: {
            guard let expiry = isoDate($0["expires_at"]) else { return true }
            return expiry > Date()
        }) { return live }
        return entries.first
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
