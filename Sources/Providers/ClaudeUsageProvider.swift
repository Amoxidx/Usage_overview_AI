import Foundation

/// Claude usage: `claude /usage` when it still prints quota lines, otherwise
/// OAuth. `CLAUDE_CODE_OAUTH_TOKEN` (process environment, else non-interactive
/// zsh / `~/.zshenv`) is sent as a 1-token `POST /v1/messages` (default model
/// alias `claude-haiku-4-5`); windows come from `anthropic-ratelimit-unified-*`
/// headers, because `GET /api/oauth/usage` permanently answers that token type
/// with 429. A 404, or a non-2xx/429 without the 5h header, lists
/// `GET /v1/models` and tries haiku ids first, then the rest, at most four
/// extra probes. The first model that returns the header is remembered. A
/// search that finds none waits an hour before listing models again. A
/// successful env reading is reused for `envHeaderCacheInterval` (default
/// 300s) without another request; the stored `fetchedAt` is kept. The keychain
/// item `Claude Code-credentials` still uses the usage endpoint. A 401/403 on
/// the env token or on `/v1/models` falls back to the keychain; any other
/// failure is returned as-is.
actor ClaudeUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude

    /// After every candidate in a run lacks the header, `/v1/models` stays quiet this long.
    private static let modelSearchCooldown: TimeInterval = 3600
    /// Extra messages probes per run, not counting the remembered or default model.
    private static let maxExtraModelProbes = 4

    private let session: URLSession
    private let runCLI: @Sendable () throws -> String
    private let loadEnvironment: @Sendable () -> ClaudeOAuth.Credential?
    private let loadKeychain: @Sendable () throws -> ClaudeOAuth.Credential
    private let envHeaderCacheInterval: TimeInterval
    private let now: @Sendable () -> Date

    /// Last model whose messages probe carried `5h-utilization`.
    private var preferredProbeModel: String?
    /// Start of the hour in which a completed search found no usable model.
    private var modelSearchFailedAt: Date?
    /// Last successful env-header reading, including its original `fetchedAt`.
    private var envHeaderCache: UsageReading?

    init(session: URLSession = .shared,
         runCLI: (@Sendable () throws -> String)? = nil,
         loadEnvironment: @escaping @Sendable () -> ClaudeOAuth.Credential? = {
             ClaudeOAuth.loadCredentialFromEnvironment()
         },
         loadKeychain: @escaping @Sendable () throws -> ClaudeOAuth.Credential = {
             try ClaudeOAuth.loadCredentialFromKeychain()
         },
         envHeaderCacheInterval: TimeInterval = 300,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.runCLI = runCLI ?? { try ClaudeUsageParser.runClaudeUsage() }
        self.loadEnvironment = loadEnvironment
        self.loadKeychain = loadKeychain
        self.envHeaderCacheInterval = envHeaderCacheInterval
        self.now = now
    }

    func fetch() async throws -> UsageReading {
        if let windows = await cliWindows() {
            return reading(windows)
        }
        if let cached = freshEnvCache() {
            return cached
        }
        if let credential = loadEnvironment() {
            do {
                let windows = try await fetchEnvHeaderWindows(credential)
                let result = reading(windows)
                envHeaderCache = result
                return result
            } catch UsageFetchError.needsAuth {
                // 401/403: the env token was rejected. The keychain may still be valid.
            }
        }
        let credential = try loadKeychain()
        let windows = try await ClaudeOAuth.fetchWindows(session: session, credential: credential)
        return reading(windows)
    }

    /// Zero and negative intervals never hit: tests pass 0 to force a request.
    /// A negative age (clock moved backwards) is not treated as fresh.
    private func freshEnvCache() -> UsageReading? {
        guard envHeaderCacheInterval > 0,
              let cached = envHeaderCache,
              let fetchedAt = cached.fetchedAt
        else { return nil }
        let age = now().timeIntervalSince(fetchedAt)
        guard age >= 0, age < envHeaderCacheInterval else { return nil }
        return cached
    }

    private func fetchEnvHeaderWindows(
        _ credential: ClaudeOAuth.Credential
    ) async throws -> [UsageWindow] {
        let model = preferredProbeModel ?? ClaudeOAuth.defaultProbeModel
        switch try await ClaudeOAuth.probeRateLimit(session: session, credential: credential, model: model) {
        case .windows(let windows):
            preferredProbeModel = model
            modelSearchFailedAt = nil
            return windows
        case .needsAuth:
            throw UsageFetchError.needsAuth
        case .missingHeaders(let status):
            // A 2xx without the header is a bad payload, not a dead model id.
            throw UsageFetchError.badResponse(status: status)
        case .retryOtherModel(let status):
            return try await searchOtherModels(credential: credential, skipping: model, failedStatus: status)
        }
    }

    private func searchOtherModels(
        credential: ClaudeOAuth.Credential,
        skipping current: String,
        failedStatus: Int
    ) async throws -> [UsageWindow] {
        if let failedAt = modelSearchFailedAt,
           now().timeIntervalSince(failedAt) < Self.modelSearchCooldown {
            throw UsageFetchError.badResponse(status: failedStatus)
        }

        let ids = try await ClaudeOAuth.listModelIDs(session: session, credential: credential)
        let candidates = ClaudeOAuth.probeCandidates(from: ids, skipping: current)
            .prefix(Self.maxExtraModelProbes)
        var lastStatus = failedStatus
        for candidate in candidates {
            switch try await ClaudeOAuth.probeRateLimit(session: session, credential: credential, model: candidate) {
            case .windows(let windows):
                preferredProbeModel = candidate
                modelSearchFailedAt = nil
                return windows
            case .needsAuth:
                throw UsageFetchError.needsAuth
            case .missingHeaders(let status):
                lastStatus = status
            case .retryOtherModel(let status):
                lastStatus = status
            }
        }
        // List came back and none of the probes (or an empty list) had the header.
        // A thrown list call never reaches here, so a down `/v1/models` does not
        // lock the search for an hour.
        modelSearchFailedAt = now()
        throw UsageFetchError.badResponse(status: lastStatus)
    }

    private func reading(_ windows: [UsageWindow]) -> UsageReading {
        UsageReading(
            id: .claude,
            status: .ok,
            windows: windows,
            headlineID: "weekly_all",
            fetchedAt: now()
        )
    }

    /// Nil when the CLI is missing, unsigned-in, or prints the post-2.1.233
    /// contribution dump instead of `Current session: N% used`.
    private func cliWindows() async -> [UsageWindow]? {
        let text: String
        do {
            let run = self.runCLI
            text = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try run() })
                }
            }
        } catch {
            return nil
        }
        return try? ClaudeUsageParser.parse(text)
    }
}

enum ClaudeUsageParser {
    /// Locate common Claude Code install paths and run `/usage`.
    static func runClaudeUsage() throws -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw UsageFetchError.unavailable("claude nicht installiert") }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageoverview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["/usage"]
        process.currentDirectoryURL = scratch
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { throw UsageFetchError.needsAuth }
        return text
    }

    /// Parses lines like:
    /// `Current session: 73% used · resets Sep 9 at 1:28pm (Europe/Berlin)`
    /// `Current week (all models): 7% used · resets Sep 14 at 5:59am (...)`
    private static let line = try! NSRegularExpression(
        pattern: #"^Current (?:(session)|week \(([^)]+)\)):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*[·•]\s*resets\s*(.+?))?\s*$"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )

    static func parse(_ text: String, now: Date = Date()) throws -> [UsageWindow] {
        let range = NSRange(text.startIndex..., in: text)
        var windows: [UsageWindow] = []
        for match in line.matches(in: text, range: range) {
            func group(_ i: Int) -> String? {
                guard let r = Range(match.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            guard let percent = group(3).flatMap(Double.init) else { continue }
            let isSession = group(1) != nil
            let id = isSession ? "session" : kind(forWeek: group(2) ?? "")
            let label = isSession ? DE.currentSession : label(for: id)
            guard !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(UsageWindow(
                id: id,
                label: label,
                usedFraction: percent / 100,
                resetsAt: group(4).flatMap { resetDate(from: $0, now: now) },
                duration: id == "session" ? 5 * 3600 : (id.hasPrefix("weekly") ? 7 * 86400 : nil)
            ))
        }
        guard windows.contains(where: { $0.id == "session" }) else {
            throw UsageFetchError.badResponse(status: 0)
        }
        // Match Claude Code / Codenotch: lead with session + all-models; keep extras after.
        let preferred = windows.filter { $0.id == "session" || $0.id == "weekly_all" }
        let extras = windows.filter { $0.id != "session" && $0.id != "weekly_all" }
        let ordered = (preferred + extras).sorted { a, b in
            order(a.id) < order(b.id)
        }
        return ordered
    }

    private static func kind(forWeek text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("all") { return "weekly_all" }
        if lower.contains("opus") { return "weekly_opus" }
        if lower.contains("sonnet") { return "weekly_sonnet" }
        if lower.contains("fable") { return "weekly_fable" }
        return "weekly_" + lower.replacingOccurrences(of: " ", with: "_")
    }

    private static func label(for id: String) -> String {
        switch id {
        case "session": return DE.currentSession
        case "weekly_all": return DE.allModels
        case "weekly_opus": return "Opus"
        case "weekly_sonnet": return "Sonnet"
        case "weekly_fable": return "Fable"
        default: return DE.allModels
        }
    }

    private static func order(_ id: String) -> Int {
        switch id {
        case "session": return 0
        case "weekly_all": return 1
        default: return 2
        }
    }

    /// Best-effort Claude `/usage` reset prose → Date.
    /// Handles `in 51 min`, `Sep 9 at 7:10pm (Europe/Berlin)`, `Sep 9 at 11pm (...)`.
    static func resetDate(from prose: String, now: Date) -> Date? {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if let m = lower.range(of: #"in\s+(\d+)\s*min"#, options: .regularExpression) {
            let digits = lower[m].filter(\.isNumber)
            if let n = Int(digits) { return now.addingTimeInterval(Double(n) * 60) }
        }
        if let m = lower.range(of: #"in\s+(\d+)\s*h"#, options: .regularExpression) {
            let digits = lower[m].filter(\.isNumber)
            if let n = Int(digits) { return now.addingTimeInterval(Double(n) * 3600) }
        }

        // Strip timezone parenthetical: "(Europe/Berlin)"
        var core = trimmed
        if let open = core.lastIndex(of: "(") {
            core = String(core[..<open]).trimmingCharacters(in: .whitespaces)
        }

        let formats = [
            "MMM d 'at' h:mma",
            "MMM d 'at' ha",
            "MMM d 'at' H:mm",
            "MMM d 'at' H"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        formatter.defaultDate = now

        for format in formats {
            formatter.dateFormat = format
            if var date = formatter.date(from: core) {
                // If parsed date is far in the past relative to now (year default), bump to this year/next
                if date < now.addingTimeInterval(-7 * 86400) {
                    var comps = Calendar.current.dateComponents(in: formatter.timeZone!, from: date)
                    let nowComps = Calendar.current.dateComponents(in: formatter.timeZone!, from: now)
                    comps.year = nowComps.year
                    if let fixed = Calendar.current.date(from: comps) {
                        date = fixed < now.addingTimeInterval(-3600) ? Calendar.current.date(byAdding: .year, value: 1, to: fixed) ?? fixed : fixed
                    }
                }
                return date
            }
        }
        return nil
    }
}
