import XCTest
@testable import UsageOverview

/// Scripted provider: tests set `next` between `refreshAll()` calls and count fetches.
private final class ScriptedUsageProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    var next: Result<UsageReading, Error>
    private(set) var fetchCount = 0

    init(id: ProviderID, next: Result<UsageReading, Error>) {
        self.id = id
        self.next = next
    }

    func fetch() async throws -> UsageReading {
        fetchCount += 1
        switch next {
        case .success(let reading):
            return reading
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
final class UsageStoreStatusTests: XCTestCase {
    private let staleAfter: TimeInterval = 5 * 60

    func testCredentialExpiredAfterGoodFetchClearsCache() async throws {
        try await assertAuthErrorClearsCache(.credentialExpired)
    }

    func testNeedsAuthAfterGoodFetchClearsCache() async throws {
        try await assertAuthErrorClearsCache(.needsAuth)
    }

    func testFreshRateLimitedLeavesReadingUnchanged() async throws {
        let fraction = 0.42
        let fake = ScriptedUsageProvider(id: .claude, next: .success(okReading(id: .claude, fraction: fraction, fetchedAt: Date())))
        let store = UsageStore(staleAfter: staleAfter, providers: [fake])
        await store.refreshAll()

        fake.next = .failure(UsageFetchError.rateLimited(retryAfter: 60))
        await store.refreshAll()

        let reading = try XCTUnwrap(store.readings[.claude])
        XCTAssertEqual(reading.status, .ok)
        XCTAssertEqual(reading.usedFraction ?? -1, fraction, accuracy: 0.0001)
    }

    func testOldRateLimitedMarksStaleButKeepsFraction() async throws {
        let fraction = 0.07
        let old = Date().addingTimeInterval(-(staleAfter + 30))
        let fake = ScriptedUsageProvider(id: .claude, next: .success(okReading(id: .claude, fraction: fraction, fetchedAt: old)))
        let store = UsageStore(staleAfter: staleAfter, providers: [fake])
        await store.refreshAll()

        fake.next = .failure(UsageFetchError.rateLimited(retryAfter: 60))
        await store.refreshAll()

        let reading = try XCTUnwrap(store.readings[.claude])
        guard case .stale = reading.status else {
            return XCTFail("expected stale, got \(reading.status)")
        }
        XCTAssertEqual(reading.usedFraction ?? -1, fraction, accuracy: 0.0001)
    }

    func testRateLimitedSkipsNextRefresh() async throws {
        let fake = ScriptedUsageProvider(id: .claude, next: .success(okReading(id: .claude, fraction: 0.21)))
        let store = UsageStore(staleAfter: staleAfter, providers: [fake])
        await store.refreshAll()
        XCTAssertEqual(fake.fetchCount, 1)

        fake.next = .failure(UsageFetchError.rateLimited(retryAfter: 60))
        await store.refreshAll()
        XCTAssertEqual(fake.fetchCount, 2)

        await store.refreshAll()
        XCTAssertEqual(fake.fetchCount, 2, "rate-limited provider must not be fetched again before nextAllowedFetch")
    }

    func testRateLimitedWithoutPriorFetchStaysEmptyError() async throws {
        let fake = ScriptedUsageProvider(id: .codex, next: .failure(UsageFetchError.rateLimited(retryAfter: 60)))
        let store = UsageStore(staleAfter: staleAfter, providers: [fake])
        await store.refreshAll()

        let reading = try XCTUnwrap(store.readings[.codex])
        guard case .error = reading.status else {
            return XCTFail("expected error, got \(reading.status)")
        }
        XCTAssertNil(reading.usedFraction)
        XCTAssertTrue(reading.windows.isEmpty)
    }

    func testNilFetchedAtOnTransientMarksStale() async throws {
        let fraction = 0.52
        let fake = ScriptedUsageProvider(
            id: .grok,
            next: .success(okReading(id: .grok, fraction: fraction, fetchedAt: nil))
        )
        let store = UsageStore(staleAfter: staleAfter, providers: [fake])
        await store.refreshAll()

        fake.next = .failure(UsageFetchError.rateLimited(retryAfter: 60))
        await store.refreshAll()

        let reading = try XCTUnwrap(store.readings[.grok])
        guard case .stale = reading.status else {
            return XCTFail("expected stale, got \(reading.status)")
        }
        XCTAssertEqual(reading.usedFraction ?? -1, fraction, accuracy: 0.0001)
    }

    func testCredentialExpiredDiscardsLastGoodSoTransientCannotResurrect() async throws {
        let old = Date().addingTimeInterval(-(staleAfter + 30))
        let fake = ScriptedUsageProvider(
            id: .grok,
            next: .success(okReading(id: .grok, fraction: 0.52, fetchedAt: old))
        )
        let store = UsageStore(staleAfter: staleAfter, providers: [fake])
        await store.refreshAll()

        fake.next = .failure(UsageFetchError.credentialExpired)
        await store.refreshAll()
        XCTAssertEqual(try XCTUnwrap(store.readings[.grok]).status, .needsAuth)

        fake.next = .failure(UsageFetchError.rateLimited(retryAfter: 60))
        await store.refreshAll()

        let reading = try XCTUnwrap(store.readings[.grok])
        XCTAssertNil(reading.usedFraction)
        XCTAssertTrue(reading.windows.isEmpty)
        if case .stale = reading.status {
            XCTFail("discarded lastGood must not return as stale, got \(reading.status)")
        }
    }

    // MARK: - Helpers

    private func assertAuthErrorClearsCache(_ error: UsageFetchError) async throws {
        let fake = ScriptedUsageProvider(id: .grok, next: .success(okReading(id: .grok, fraction: 0.52)))
        let store = UsageStore(staleAfter: staleAfter, providers: [fake])
        await store.refreshAll()
        XCTAssertEqual(try XCTUnwrap(store.readings[.grok]).usedFraction ?? -1, 0.52, accuracy: 0.0001)

        fake.next = .failure(error)
        await store.refreshAll()

        let reading = try XCTUnwrap(store.readings[.grok])
        XCTAssertEqual(reading.status, .needsAuth)
        XCTAssertNil(reading.usedFraction)
        XCTAssertTrue(reading.windows.isEmpty)
    }

    private func okReading(id: ProviderID, fraction: Double, fetchedAt: Date? = Date()) -> UsageReading {
        UsageReading(
            id: id,
            status: .ok,
            windows: [UsageWindow(id: "headline", label: "Test", usedFraction: fraction)],
            headlineID: "headline",
            fetchedAt: fetchedAt
        )
    }
}
