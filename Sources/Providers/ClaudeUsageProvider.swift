import Foundation

/// Claude usage via `claude /usage` Process, with documented keychain/OAuth stub fallback.
///
/// Prefer the CLI: Claude Code rotates keychain items frequently, so borrowing
/// the token often re-prompts. Asking `claude` itself uses a credential the CLI
/// already holds. Keychain OAuth against `https://api.anthropic.com/api/oauth/usage`
/// is only sketched as a TODO fallback when the binary is missing.
actor ClaudeUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude

    private let session: URLSession
    private let runCLI: @Sendable () throws -> String

    init(session: URLSession = .shared,
         runCLI: (@Sendable () throws -> String)? = nil) {
        self.session = session
        self.runCLI = runCLI ?? { try ClaudeUsageParser.runClaudeUsage() }
    }

    func fetch() async throws -> UsageReading {
        let text: String
        do {
            let run = self.runCLI
            text = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try run() })
                }
            }
        } catch let error as UsageFetchError {
            throw error
        } catch {
            // TODO: Keychain fallback — read Claude Code OAuth token and GET
            // https://api.anthropic.com/api/oauth/usage with anthropic-beta: oauth-2025-04-20.
            // Intentionally not implemented here to avoid keychain prompts on every poll.
            throw UsageFetchError.unavailable("claude CLI nicht gefunden oder fehlgeschlagen")
        }

        let windows = try ClaudeUsageParser.parse(text)
        return UsageReading(
            id: .claude,
            status: .ok,
            windows: windows,
            headlineID: "weekly_all",
            fetchedAt: Date()
        )
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
