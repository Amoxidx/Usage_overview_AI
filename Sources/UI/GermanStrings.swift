import Foundation

/// German UI copy. Code and comments stay English.
enum DE {
    static let usageSuffix = " Nutzung"
    static func usageTitle(_ provider: String) -> String { provider + usageSuffix }

    static let currentSession = "Aktuelle Sitzung"
    static let allModels = "Alle Modelle"
    static let weeklyLimit = "Wochenlimit"
    static let monthlyLimit = "Monatslimit"
    static let longerWindow = "Längeres Fenster"
    static let fiveHourLimit = "5h-Limit"
    static let grokBuild = "Grok Build"
    static let used = "genutzt"
    static let noReading = "Keine Messung"
    static let needsAuth = "Anmeldung erforderlich"
    static let needsInstall = "CLI nicht installiert"
    static let stale = "Veraltet"
    static let error = "Fehler"
    static let nothingMetered = "Nichts gemessen"
    static let demoBadge = "DEMO"

    /// Shown as the clickable-looking hint line under `needsAuth`.
    static let clickToLogin = "Zum Anmelden anklicken"
    /// Shown under `needsInstall` — points at the CLI, never at a guessed URL.
    static let installHint = "CLI installieren, dann erneut versuchen"

    static func resetsIn(minutes: Int) -> String {
        if minutes < 60 { return "Zurücksetzen in \(minutes) Min." }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return "Zurücksetzen in \(hours) Std." }
        return "Zurücksetzen in \(hours) Std. \(rem) Min."
    }

    static func resetsOn(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days == 0 {
            formatter.dateFormat = "HH:mm"
            return "Zurücksetzen \(formatter.string(from: date))"
        }
        formatter.dateFormat = "E HH:mm"
        return "Zurücksetzen \(formatter.string(from: date))"
    }

    static func resetCopy(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Zurücksetzen bald" }
        if seconds < 3600 {
            return resetsIn(minutes: max(1, Int((seconds / 60).rounded())))
        }
        if seconds < 48 * 3600 {
            let minutes = Int((seconds / 60).rounded())
            return resetsIn(minutes: minutes)
        }
        return resetsOn(date, now: now)
    }
}
