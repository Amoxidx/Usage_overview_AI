import Foundation
import Combine

/// Polls providers, keeps last-good cache, surfaces error/stale — never invents %.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var readings: [ProviderID: UsageReading]
    @Published private(set) var isDemo: Bool

    private var timer: Timer?
    private let pollInterval: TimeInterval
    private let staleAfter: TimeInterval
    private let providers: [any UsageProvider]
    private var lastGood: [ProviderID: UsageReading] = [:]
    private var nextAllowedFetch: [ProviderID: Date] = [:]

    init(pollInterval: TimeInterval = 60,
         staleAfter: TimeInterval = 5 * 60,
         providers: [any UsageProvider]? = nil) {
        self.pollInterval = pollInterval
        self.staleAfter = staleAfter
        self.isDemo = DemoData.isEnabled
        if DemoData.isEnabled {
            self.providers = []
            self.readings = DemoData.readings()
            self.lastGood = self.readings
        } else {
            self.providers = providers ?? [
                ClaudeUsageProvider(),
                CodexUsageProvider(),
                GrokUsageProvider()
            ]
            var initial: [ProviderID: UsageReading] = [:]
            for id in ProviderID.allCases {
                initial[id] = .empty(id, status: .needsAuth)
            }
            self.readings = initial
        }
    }

    func start() {
        Task { await refreshAll() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshAll() async {
        if DemoData.isEnabled {
            isDemo = true
            readings = DemoData.readings()
            return
        }
        await withTaskGroup(of: (ProviderID, Result<UsageReading, Error>).self) { group in
            for provider in providers {
                if let until = nextAllowedFetch[provider.id], Date() < until {
                    continue
                }
                group.addTask {
                    do {
                        let reading = try await provider.fetch()
                        return (provider.id, .success(reading))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                apply(id: id, result: result)
            }
        }
    }

    private func apply(id: ProviderID, result: Result<UsageReading, Error>) {
        switch result {
        case .success(let reading):
            lastGood[id] = reading
            readings[id] = reading
            nextAllowedFetch[id] = nil
        case .failure(let error):
            if let fetch = error as? UsageFetchError {
                switch fetch {
                case .needsAuth, .credentialExpired:
                    // An expired token does not become valid by waiting; a frozen percentage claims recency that is not there.
                    lastGood[id] = nil
                    readings[id] = UsageReading.empty(id, status: .needsAuth)
                    return
                case .rateLimited(let retryAfter):
                    nextAllowedFetch[id] = Date().addingTimeInterval(max(retryAfter, pollInterval))
                case .nothingMetered, .badResponse, .unavailable:
                    break
                }
            }

            let status: ProviderStatus
            if let fetch = error as? UsageFetchError {
                switch fetch {
                case .needsAuth, .credentialExpired:
                    status = .needsAuth
                case .nothingMetered:
                    status = .nothingMetered
                case .rateLimited, .badResponse, .unavailable:
                    status = .error(String(describing: fetch))
                }
            } else {
                status = .error(error.localizedDescription)
            }

            if var cached = lastGood[id], !cached.windows.isEmpty {
                let isTransient: Bool
                if let fetch = error as? UsageFetchError {
                    switch fetch {
                    case .rateLimited, .badResponse, .unavailable:
                        isTransient = true
                    case .needsAuth, .credentialExpired, .nothingMetered:
                        isTransient = false
                    }
                } else {
                    isTransient = false
                }
                if isTransient, let fetchedAt = cached.fetchedAt, Date().timeIntervalSince(fetchedAt) < staleAfter {
                    return
                }
                cached.status = .stale(since: cached.fetchedAt ?? Date())
                readings[id] = cached
            } else {
                readings[id] = UsageReading(id: id, status: status, windows: [], headlineID: nil, fetchedAt: nil)
            }
        }
    }
}
