import Foundation
import Combine

/// Polls providers, keeps last-good cache, surfaces error/stale — never invents %.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var readings: [ProviderID: UsageReading]
    @Published private(set) var isDemo: Bool

    private var timer: Timer?
    private let pollInterval: TimeInterval
    private let providers: [any UsageProvider]
    private var lastGood: [ProviderID: UsageReading] = [:]
    /// Short-lived rapid re-poll of exactly one provider after a login attempt
    /// (see `beginLoginWatch`), so the ring doesn't wait for the next 60s tick.
    private var loginWatchTask: Task<Void, Never>?

    init(pollInterval: TimeInterval = 60,
         providers: [any UsageProvider]? = nil) {
        self.pollInterval = pollInterval
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
        loginWatchTask?.cancel()
        loginWatchTask = nil
    }

    func refreshAll() async {
        if DemoData.isEnabled {
            isDemo = true
            readings = DemoData.readings()
            return
        }
        await withTaskGroup(of: (ProviderID, Result<UsageReading, Error>).self) { group in
            for provider in providers {
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
                await apply(id: id, result: result)
            }
        }
    }

    /// After the user triggers a login (`ProviderLoginLauncher.openLoginTerminal`),
    /// poll a cheap, non-`fetch()` signal every few seconds for a short window
    /// instead of waiting for the next full 60s cycle. Only the triggering
    /// provider is touched — the other two stay on the regular timer.
    func beginLoginWatch(for id: ProviderID, timeout: TimeInterval = 150, pollEvery: TimeInterval = 4) {
        guard !DemoData.isEnabled, let provider = providers.first(where: { $0.id == id }) else { return }
        loginWatchTask?.cancel()
        loginWatchTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(timeout)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
                if Task.isCancelled { return }
                guard await ProviderLoginLauncher.isLoggedIn(for: id) else { continue }
                guard let self else { return }
                let result: Result<UsageReading, Error>
                do {
                    result = .success(try await provider.fetch())
                } catch {
                    result = .failure(error)
                }
                await self.apply(id: id, result: result)
                return
            }
        }
    }

    private func apply(id: ProviderID, result: Result<UsageReading, Error>) async {
        switch result {
        case .success(let reading):
            lastGood[id] = reading
            readings[id] = reading
        case .failure(let error):
            var status: ProviderStatus
            if let fetch = error as? UsageFetchError {
                switch fetch {
                case .needsAuth, .credentialExpired:
                    status = .needsAuth
                case .unavailable:
                    status = .needsInstall
                case .nothingMetered:
                    status = .nothingMetered
                case .rateLimited, .badResponse:
                    status = .error(String(describing: fetch))
                }
            } else {
                status = .error(error.localizedDescription)
            }

            // Codex/Grok only ever throw `.needsAuth` (their auth-file check
            // can't tell "missing file" from "CLI never installed") — ask the
            // launcher's real binary check to upgrade the status when that's
            // actually the case, so onboarding shows "install" not "sign in".
            if case .needsAuth = status, await !ProviderLoginLauncher.isInstalled(for: id) {
                status = .needsInstall
            }

            if var cached = lastGood[id], !cached.windows.isEmpty {
                cached.status = .stale(since: cached.fetchedAt ?? Date())
                readings[id] = cached
            } else {
                readings[id] = UsageReading(id: id, status: status, windows: [], headlineID: nil, fetchedAt: nil)
            }
        }
    }
}
