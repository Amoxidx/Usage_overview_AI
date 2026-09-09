import Foundation

/// How a fetch failed — never invent a percentage for these.
enum UsageFetchError: Error, Equatable, Sendable {
    case needsAuth
    case credentialExpired
    case badResponse(status: Int)
    case nothingMetered
    case unavailable(String)
    case rateLimited(retryAfter: TimeInterval)
}

enum ProviderStatus: Equatable, Sendable {
    case ok
    case stale(since: Date)
    case needsAuth
    case error(String)
    case nothingMetered
}

/// Latest honest reading for one provider.
struct UsageReading: Identifiable, Equatable, Sendable {
    let id: ProviderID
    var status: ProviderStatus
    var windows: [UsageWindow]
    /// Window id that drives the ring (declared, not "first in array").
    var headlineID: String?
    var fetchedAt: Date?

    var headline: UsageWindow? {
        if let headlineID {
            return windows.first { $0.id == headlineID } ?? windows.first
        }
        return windows.first
    }

    /// Ring percentage — nil when there is no honest number.
    var usedFraction: Double? {
        guard case .ok = status else {
            // Stale may still show last-good if windows are present.
            if case .stale = status { return headline?.usedFraction }
            return nil
        }
        return headline?.usedFraction
    }

    static func empty(_ id: ProviderID, status: ProviderStatus = .needsAuth) -> UsageReading {
        UsageReading(id: id, status: status, windows: [], headlineID: nil, fetchedAt: nil)
    }
}

enum PercentFormat {
    /// Whole percent for the ring label; tenths only in the awkward <1% band.
    static func text(for fraction: Double) -> String {
        let value = fraction * 100
        if value > 0, value < 1 {
            let tenths = (value * 10).rounded() / 10
            if tenths < 0.1 { return "<0,1" }
            return String(format: "%.1f", locale: Locale(identifier: "de_DE"), tenths)
        }
        return "\(Int(value.rounded()))"
    }

    static func usedLabel(for fraction: Double) -> String {
        "\(text(for: fraction))% genutzt"
    }
}
