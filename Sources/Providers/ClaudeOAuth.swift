import Foundation

/// Read-only Claude Code OAuth token, then usage windows.
/// `CLAUDE_CODE_OAUTH_TOKEN` (process environment, else non-interactive zsh,
/// which reads `~/.zshenv`) is a long-lived setup token: `GET /api/oauth/usage`
/// answers it with a permanent 429, so that path reads rate-limit headers from
/// a 1-token Haiku `POST /v1/messages`. The login-keychain access token still
/// uses `GET /api/oauth/usage`. Used when `claude /usage` no longer prints
/// `Current session: N% used` (CLI 2.1.233+ dumps contribution stats instead).
enum ClaudeOAuth {
    static let service = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let betaHeader = "oauth-2025-04-20"
    static let messagesAPIVersion = "2023-06-01"
    /// Smallest request that still returns `anthropic-ratelimit-unified-*`.
    static let rateLimitProbeBody = #"{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}"#

    struct Credential: Sendable {
        let accessToken: String
        let expiresAt: Date
    }

    static func loadCredential(
        now: Date = Date(),
        read: () throws -> Data = { try readKeychain() }
    ) throws -> Credential {
        try credential(from: try read(), now: now)
    }

    /// Prefer the login-name item: `security -s SERVICE -w` returns the first
    /// match, which on some Macs is an MCP-only blob (`acct=unknown`) without
    /// `claudeAiOauth`.
    static func loadCredentialFromKeychain(now: Date = Date()) throws -> Credential {
        let blobs = readKeychainBlobs()
        var last: Error = UsageFetchError.needsAuth
        for data in blobs {
            do { return try credential(from: data, now: now) } catch { last = error }
        }
        throw last
    }

    /// Long-lived `claude setup-token` value. `expiresAt` is not carried by the
    /// variable; a one-hour horizon only stops expiry checks from treating it
    /// as already dead. The token is never logged. `read` defaults to the
    /// process environment, then zsh, and is injectable so tests start no shell.
    static func loadCredentialFromEnvironment(
        now: Date = Date(),
        read: () -> String? = { readEnvironmentToken() }
    ) -> Credential? {
        guard let token = read()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return Credential(accessToken: token, expiresAt: now.addingTimeInterval(3600))
    }

    static func readEnvironmentToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readShell: () -> String? = { readZshEnvironmentToken() }
    ) -> String? {
        if let direct = environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty {
            return direct
        }
        guard let shell = readShell()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shell.isEmpty
        else { return nil }
        return shell
    }

    /// No `-l` and no `-i`: every zsh reads `~/.zshenv`, login/interactive files stay out.
    /// Stderr goes to `/dev/null` so a noisy startup file cannot fill a pipe and
    /// stall the read past the watchdog. The token is never logged.
    private static func readZshEnvironmentToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", #"printf %s "${CLAUDE_CODE_OAUTH_TOKEN-}""#]
        process.standardInput = FileHandle.nullDevice
        if let sink = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = sink
        } else {
            process.standardError = Pipe()
        }
        let out = Pipe()
        process.standardOutput = out
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func credential(from data: Data, now: Date) throws -> Credential {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw UsageFetchError.needsAuth }

        let expires: Date
        if let ms = number(oauth["expiresAt"]) {
            expires = Date(timeIntervalSince1970: ms / 1000)
        } else {
            expires = now.addingTimeInterval(30 * 60)
        }
        if expires <= now { throw UsageFetchError.credentialExpired }
        return Credential(accessToken: token, expiresAt: expires)
    }

    static func readKeychain() throws -> Data {
        let blobs = readKeychainBlobs()
        guard let first = blobs.first else { throw UsageFetchError.needsAuth }
        return first
    }

    static func readKeychainBlobs() -> [Data] {
        var seen = Set<Data>()
        var blobs: [Data] = []
        let attempts: [[String]] = [
            ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"],
            ["find-generic-password", "-s", service, "-w"]
        ]
        for args in attempts {
            guard let data = try? runSecurity(args), !data.isEmpty, seen.insert(data).inserted else { continue }
            blobs.append(data)
        }
        return blobs
    }

    /// `security(1)` is already on the item's ACL (Claude Code put it there).
    /// `SecItemCopyMatching` from this ad-hoc app is denied silently because
    /// the app is `LSUIElement` and has no stable code identity.
    static func runSecurity(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw UsageFetchError.needsAuth
        }
        return data
    }

    static func fetchWindows(
        session: URLSession,
        credential: Credential,
        now: Date = Date()
    ) async throws -> [UsageWindow] {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageFetchError.needsAuth }
        if status == 429 {
            throw UsageFetchError.rateLimited(retryAfter: retryAfterSeconds(from: response) ?? 60)
        }
        guard (200..<300).contains(status) else { throw UsageFetchError.badResponse(status: status) }
        return try ClaudeOAuthParser.windows(from: data, now: now)
    }

    /// `POST /v1/messages` with a 1-token Haiku probe. Utilization headers are
    /// fractions in 0...1, not percentages; resets are unix seconds. The body
    /// is ignored. `now` is unused because those resets are absolute.
    static func fetchWindowsFromRateLimitHeaders(
        session: URLSession,
        credential: Credential,
        now: Date = Date()
    ) async throws -> [UsageWindow] {
        _ = now
        var request = URLRequest(url: messagesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(rateLimitProbeBody.utf8)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(messagesAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageFetchError.needsAuth }

        let headerWindows = (response as? HTTPURLResponse).flatMap { windowsFromRateLimitHeaders($0) }
        if status == 429 {
            if let headerWindows { return headerWindows }
            throw UsageFetchError.rateLimited(retryAfter: retryAfterSeconds(from: response) ?? 60)
        }
        guard (200..<300).contains(status) else { throw UsageFetchError.badResponse(status: status) }
        guard let headerWindows else { throw UsageFetchError.badResponse(status: status) }
        return headerWindows
    }

    /// Session is required. A missing weekly utilization omits `weekly_all`
    /// instead of inventing a percentage. Header names are matched
    /// case-insensitively by `value(forHTTPHeaderField:)`.
    private static func windowsFromRateLimitHeaders(_ http: HTTPURLResponse) -> [UsageWindow]? {
        guard let sessionUsed = fraction(http, "anthropic-ratelimit-unified-5h-utilization") else {
            return nil
        }
        var windows = [
            UsageWindow(
                id: "session",
                label: DE.currentSession,
                usedFraction: sessionUsed,
                resetsAt: unixDate(http, "anthropic-ratelimit-unified-5h-reset"),
                duration: 5 * 3600
            )
        ]
        if let weeklyUsed = fraction(http, "anthropic-ratelimit-unified-7d-utilization") {
            windows.append(UsageWindow(
                id: "weekly_all",
                label: DE.allModels,
                usedFraction: weeklyUsed,
                resetsAt: unixDate(http, "anthropic-ratelimit-unified-7d-reset"),
                duration: 7 * 86400
            ))
        }
        return windows
    }

    private static func fraction(_ http: HTTPURLResponse, _ name: String) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Double(raw),
              value.isFinite
        else { return nil }
        return value
    }

    private static func unixDate(_ http: HTTPURLResponse, _ name: String) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let seconds = TimeInterval(raw),
              seconds.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Delta-seconds only (`Retry-After` as an integer or double). Nil means
    /// missing or unreadable, and the caller uses 60.
    private static func retryAfterSeconds(from response: URLResponse) -> TimeInterval? {
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let seconds = TimeInterval(raw),
              seconds.isFinite,
              seconds >= 0
        else { return nil }
        return seconds
    }

    private static func number(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }
}

enum ClaudeOAuthParser {
    static func windows(from data: Data, now: Date = Date()) throws -> [UsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.badResponse(status: 0)
        }

        var windows: [UsageWindow] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = number(limit["percent"])
                else { continue }
                let id = normalize(kind)
                guard !windows.contains(where: { $0.id == id }) else { continue }
                windows.append(UsageWindow(
                    id: id,
                    label: label(for: id),
                    usedFraction: percent / 100,
                    resetsAt: AuthReaders.isoDate(limit["resets_at"]),
                    duration: duration(for: id)
                ))
            }
        }

        mergeNamed(root["five_hour"], id: "session", into: &windows)
        mergeNamed(root["seven_day"], id: "weekly_all", into: &windows)

        guard windows.contains(where: { $0.id == "session" }) else {
            throw UsageFetchError.badResponse(status: 0)
        }
        return windows.sorted { order($0.id) < order($1.id) }
    }

    private static func mergeNamed(_ any: Any?, id: String, into windows: inout [UsageWindow]) {
        guard !windows.contains(where: { $0.id == id }),
              let obj = any as? [String: Any],
              let percent = number(obj["utilization"])
        else { return }
        windows.append(UsageWindow(
            id: id,
            label: label(for: id),
            usedFraction: percent / 100,
            resetsAt: AuthReaders.isoDate(obj["resets_at"]),
            duration: duration(for: id)
        ))
    }

    private static func normalize(_ kind: String) -> String {
        switch kind {
        case "session", "five_hour": return "session"
        case "seven_day": return "weekly_all"
        default: return kind
        }
    }

    private static func label(for id: String) -> String {
        switch id {
        case "session": return DE.currentSession
        case "weekly_all": return DE.allModels
        case "weekly_opus": return "Opus"
        case "weekly_sonnet": return "Sonnet"
        case "weekly_fable", "weekly_scoped": return "Fable"
        default: return DE.allModels
        }
    }

    private static func duration(for id: String) -> TimeInterval? {
        if id == "session" { return 5 * 3600 }
        if id.hasPrefix("weekly") { return 7 * 86400 }
        return nil
    }

    private static func order(_ id: String) -> Int {
        switch id {
        case "session": return 0
        case "weekly_all": return 1
        default: return 2
        }
    }

    private static func number(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }
}
