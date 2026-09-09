import Foundation

/// Beautiful sample readings matching the design screenshot (73% / 21% / 52%).
enum DemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["USAGE_OVERVIEW_DEMO"] == "1"
    }

    static func readings(now: Date = Date(), calendar: Calendar = .current) -> [ProviderID: UsageReading] {
        let sessionReset = now.addingTimeInterval(51 * 60)
        let thursdayish = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(2 * 86400)

        return [
            .claude: UsageReading(
                id: .claude,
                status: .ok,
                windows: [
                    UsageWindow(id: "session", label: DE.currentSession,
                                usedFraction: 0.73, resetsAt: sessionReset, duration: 5 * 3600),
                    UsageWindow(id: "weekly_all", label: DE.allModels,
                                usedFraction: 0.07, resetsAt: thursdayish, duration: 7 * 86400)
                ],
                headlineID: "weekly_all",
                fetchedAt: now
            ),
            .codex: UsageReading(
                id: .codex,
                status: .ok,
                windows: [
                    UsageWindow(id: "primary", label: DE.fiveHourLimit,
                                usedFraction: 0.21, resetsAt: now.addingTimeInterval(3 * 3600), duration: 5 * 3600),
                    UsageWindow(id: "secondary", label: DE.weeklyLimit,
                                usedFraction: 0.08, resetsAt: now.addingTimeInterval(4 * 86400), duration: 7 * 86400)
                ],
                headlineID: "primary",
                fetchedAt: now
            ),
            .grok: UsageReading(
                id: .grok,
                status: .ok,
                windows: [
                    UsageWindow(id: "credits", label: DE.grokBuild,
                                usedFraction: 0.52, resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400)
                ],
                headlineID: "credits",
                fetchedAt: now
            )
        ]
    }
}
