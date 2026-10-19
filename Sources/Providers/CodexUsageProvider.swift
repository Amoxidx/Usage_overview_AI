import Foundation

/// Codex / ChatGPT usage from local `~/.codex/auth.json` + usage endpoint.
/// Refreshes the ChatGPT OAuth token when it is expired, inside 120 seconds of expiry, or rejected.
actor CodexUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .codex

    private let session: URLSession
    private let authURL: URL
    private let now: @Sendable () -> Date
    /// One in-flight refresh. The actor re-enters on await, and a second exchange would rotate the refresh token twice.
    private var refreshTask: Task<AuthReaders.CodexCredential, Error>?
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    init(
        session: URLSession = .shared,
        authURL: URL = AuthReaders.defaultCodexAuthURL(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.authURL = authURL
        self.now = now
    }

    func fetch() async throws -> UsageReading {
        let fetchedAt = now()
        var credential = try AuthReaders.loadCodex(from: authURL)
        if accessTokenNeedsRefresh(credential, now: fetchedAt) {
            credential = try await refreshSerialized(credential)
        }

        do {
            return try await fetchUsage(with: credential, fetchedAt: fetchedAt)
        } catch UsageFetchError.needsAuth {
            let refreshed = try await refreshSerialized(credential)
            return try await fetchUsage(with: refreshed, fetchedAt: now())
        }
    }

    private func accessTokenNeedsRefresh(
        _ credential: AuthReaders.CodexCredential,
        now: Date
    ) -> Bool {
        guard let expiresAt = credential.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 120
    }

    private func refreshSerialized(
        _ credential: AuthReaders.CodexCredential
    ) async throws -> AuthReaders.CodexCredential {
        if let refreshTask {
            return try await refreshTask.value
        }

        let authURL = self.authURL
        let session = self.session
        let now = self.now()
        let task = Task {
            try await AuthReaders.refreshCodex(
                credential: credential,
                authURL: authURL,
                session: session,
                now: now
            )
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func fetchUsage(
        with credential: AuthReaders.CodexCredential,
        fetchedAt: Date
    ) async throws -> UsageReading {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageFetchError.needsAuth }
        if status == 429 { throw UsageFetchError.rateLimited(retryAfter: 60) }
        guard (200..<300).contains(status) else { throw UsageFetchError.badResponse(status: status) }

        let windows = try CodexUsageParser.windows(from: data)
        return UsageReading(
            id: .codex,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id,
            fetchedAt: fetchedAt
        )
    }
}

enum CodexUsageParser {
    private struct Response: Decodable {
        let rate_limit: RateLimit?
    }
    private struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }
    private struct Window: Decodable {
        let limit_window_seconds: Double?
        let used_percent: Double?
        let reset_at: Double?
        let reset_after_seconds: Double?
    }

    static func windows(from data: Data, now: Date = Date()) throws -> [UsageWindow] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageFetchError.badResponse(status: 0)
        }

        var result: [UsageWindow] = []
        for (id, window) in [("primary", response.rate_limit?.primary_window),
                             ("secondary", response.rate_limit?.secondary_window)] {
            guard let window, let percent = window.used_percent else { continue }
            let resetsAt = window.reset_at.map { Date(timeIntervalSince1970: $0) }
                ?? window.reset_after_seconds.map { now.addingTimeInterval($0) }
            result.append(UsageWindow(
                id: id,
                label: label(windowSeconds: window.limit_window_seconds ?? 0, fallback: id),
                usedFraction: percent / 100,
                resetsAt: resetsAt,
                duration: window.limit_window_seconds
            ))
        }
        guard !result.isEmpty else { throw UsageFetchError.nothingMetered }
        return result
    }

    static func label(windowSeconds: Double, fallback: String) -> String {
        guard windowSeconds > 0 else {
            return fallback == "primary" ? DE.currentSession : DE.longerWindow
        }
        let minutes = windowSeconds / 60
        if minutes < 60 { return "\(Int(minutes))m-Limit" }
        if minutes < 60 * 24 {
            let hours = Int(minutes / 60)
            return hours == 5 ? DE.fiveHourLimit : "\(hours)h-Limit"
        }
        let days = Int((minutes / (60 * 24)).rounded())
        switch days {
        case 7: return DE.weeklyLimit
        case 30: return DE.monthlyLimit
        default: return "\(days)d-Limit"
        }
    }
}
