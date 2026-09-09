import Foundation

/// Grok Build credits from `~/.grok/auth.json` + billing endpoint (read-only).
actor GrokUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .grok

    private let session: URLSession
    private let authURL: URL
    private let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    init(session: URLSession = .shared, authURL: URL = AuthReaders.grokAuthURL) {
        self.session = session
        self.authURL = authURL
    }

    func fetch() async throws -> UsageReading {
        let credentials = try AuthReaders.loadGrok(from: authURL)
        if credentials.expiresAt <= Date() { throw UsageFetchError.credentialExpired }

        var request = URLRequest(url: creditsURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageFetchError.needsAuth }
        if status == 429 { throw UsageFetchError.rateLimited(retryAfter: 60) }
        guard (200..<300).contains(status),
              let text = String(data: data, encoding: .utf8)
        else { throw UsageFetchError.badResponse(status: status) }

        let windows = try GrokUsageParser.windows(creditsJSON: text)
        return UsageReading(
            id: .grok,
            status: .ok,
            windows: windows,
            headlineID: "credits",
            fetchedAt: Date()
        )
    }
}

enum GrokUsageParser {
    static func windows(creditsJSON: String) throws -> [UsageWindow] {
        guard let data = creditsJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = root["config"] as? [String: Any]
        else { throw UsageFetchError.badResponse(status: 0) }

        var windows: [UsageWindow] = []
        let currentPeriod = credits["currentPeriod"] as? [String: Any]
        let currentEnd = AuthReaders.isoDate(currentPeriod?["end"])
        let creditsReset = currentEnd ?? AuthReaders.isoDate(credits["billingPeriodEnd"])
        let start = currentEnd == nil
            ? AuthReaders.isoDate(credits["billingPeriodStart"])
            : AuthReaders.isoDate(currentPeriod?["start"])
        let duration = start.flatMap { s in creditsReset.map { $0.timeIntervalSince(s) } }

        if let fraction = percent(credits["creditUsagePercent"]) {
            windows.append(UsageWindow(
                id: "credits",
                label: productLabel(credits) ?? DE.grokBuild,
                usedFraction: fraction,
                resetsAt: creditsReset,
                duration: duration
            ))
        } else if let products = credits["productUsage"] as? [[String: Any]] {
            for product in products {
                guard let fraction = percent(product["usagePercent"]) else { continue }
                let name = (product["product"] as? String).map(humanize) ?? DE.grokBuild
                windows.append(UsageWindow(
                    id: windows.isEmpty ? "credits" : ((product["product"] as? String) ?? name),
                    label: name,
                    usedFraction: fraction,
                    resetsAt: creditsReset,
                    duration: duration
                ))
            }
        }

        if windows.isEmpty,
           let weekly = currentPeriod,
           (weekly["type"] as? String)?.contains("WEEKLY") == true {
            windows.append(UsageWindow(
                id: "credits",
                label: DE.weeklyLimit,
                usedFraction: 0,
                resetsAt: AuthReaders.isoDate(weekly["end"]) ?? creditsReset,
                duration: duration
            ))
        }

        guard !windows.isEmpty else { throw UsageFetchError.nothingMetered }
        return windows
    }

    private static func productLabel(_ credits: [String: Any]) -> String? {
        guard let products = credits["productUsage"] as? [[String: Any]],
              let name = products.first?["product"] as? String
        else { return nil }
        return humanize(name)
    }

    static func humanize(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return result
    }

    private static func percent(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        return number.doubleValue / 100
    }
}
