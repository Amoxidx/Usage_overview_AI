import Foundation

/// Read-only Claude Code OAuth token, then usage windows.
/// `CLAUDE_CODE_OAUTH_TOKEN` (process environment, else non-interactive zsh,
/// which reads `~/.zshenv`) is a long-lived setup token: `GET /api/oauth/usage`
/// answers it with a permanent 429, so that path reads rate-limit headers from
/// a 1-token `POST /v1/messages`. The default model is the alias
/// `claude-haiku-4-5`. A 404, or a non-2xx response without
/// `anthropic-ratelimit-unified-5h-utilization`, is not a usable probe; the
/// provider then lists `GET /v1/models`. The login-keychain access token still
/// uses `GET /api/oauth/usage`. Used when `claude /usage` no longer prints
/// `Current session: N% used` (CLI 2.1.233+ dumps contribution stats instead).
enum ClaudeOAuth {
    static let service = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let modelsURL = URL(string: "https://api.anthropic.com/v1/models")!
    static let betaHeader = "oauth-2025-04-20"
    static let messagesAPIVersion = "2023-06-01"
    /// Alias, not a dated snapshot. A dated id 404s once that snapshot is gone.
    static let defaultProbeModel = "claude-haiku-4-5"

    /// One messages probe. Header presence is the success condition: a 429 that
    /// still carries `5h-utilization` is a reading. 404 always asks for another
    /// model, even if a header sneaks through. A 2xx without the header is
    /// `missingHeaders` and does not by itself start a search.
    enum RateLimitProbeResult: Sendable {
        case windows([UsageWindow])
        case needsAuth
        case retryOtherModel(status: Int)
        case missingHeaders(status: Int)
    }

    /// Stable JSON: key order must not depend on `JSONSerialization`.
    static func rateLimitProbeBody(model: String) -> String {
        #"{"model":"\#(model)","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}"#
    }

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

    /// `POST /v1/messages` with a 1-token probe. Utilization headers are
    /// fractions in 0...1, not percentages; resets are unix seconds. The
    /// messages body is ignored.
    static func probeRateLimit(
        session: URLSession,
        credential: Credential,
        model: String
    ) async throws -> RateLimitProbeResult {
        var request = URLRequest(url: messagesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(rateLimitProbeBody(model: model).utf8)
        authorize(&request, credential: credential)
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { return .needsAuth }
        if status == 404 { return .retryOtherModel(status: status) }
        if let http = response as? HTTPURLResponse, let windows = windowsFromRateLimitHeaders(http) {
            return .windows(windows)
        }
        if (200..<300).contains(status) { return .missingHeaders(status: status) }
        return .retryOtherModel(status: status)
    }

    /// `GET /v1/models`. Only `data[].id` is read, in list order. 401/403 is
    /// `needsAuth` so the caller can fall back to the keychain. Any other
    /// non-2xx is `badResponse` and is not a completed candidate search.
    static func listModelIDs(
        session: URLSession,
        credential: Credential
    ) async throws -> [String] {
        var request = URLRequest(url: modelsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        authorize(&request, credential: credential)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageFetchError.needsAuth }
        guard (200..<300).contains(status) else { throw UsageFetchError.badResponse(status: status) }
        guard let ids = modelIDs(from: data) else { throw UsageFetchError.badResponse(status: status) }
        return ids
    }

    /// Haiku ids first, then everything else, each group in list order.
    /// `current` is skipped so a failed probe is not repeated in the same run.
    static func probeCandidates(from ids: [String], skipping current: String) -> [String] {
        var haiku: [String] = []
        var rest: [String] = []
        for id in ids where !id.isEmpty && id != current {
            if id.range(of: "haiku", options: .caseInsensitive) != nil {
                haiku.append(id)
            } else {
                rest.append(id)
            }
        }
        return haiku + rest
    }

    /// Nil when the body has no `data` array. Non-string ids are skipped.
    static func modelIDs(from data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [Any]
        else { return nil }
        var ids: [String] = []
        for row in rows {
            guard let object = row as? [String: Any],
                  let id = object["id"] as? String,
                  !id.isEmpty
            else { continue }
            ids.append(id)
        }
        return ids
    }

    private static func authorize(_ request: inout URLRequest, credential: Credential) {
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(messagesAPIVersion, forHTTPHeaderField: "anthropic-version")
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
