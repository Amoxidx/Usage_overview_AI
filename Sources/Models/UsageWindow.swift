import Foundation

/// One metered limit window reported by a provider.
struct UsageWindow: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// German UI label (e.g. "Aktuelle Sitzung").
    let label: String
    /// Used fraction in 0...1+. Nil means the provider did not state a percentage.
    let usedFraction: Double?
    let resetsAt: Date?
    let duration: TimeInterval?

    init(id: String, label: String, usedFraction: Double?, resetsAt: Date? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.duration = duration
    }
}
