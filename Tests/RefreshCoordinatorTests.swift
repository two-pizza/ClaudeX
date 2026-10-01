import XCTest
@testable import ClaudeXPolicy

final class RefreshCoordinatorTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var clock: Date!
    private var calls: [String: Int]!
    private var pending: [String: RefreshCoordinator.Completion]!

    override func setUp() {
        suite = "ClaudeXTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        calls = [:]
        pending = [:]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make() -> RefreshCoordinator {
        var fetchers: [String: RefreshCoordinator.Fetch] = [:]
        for id in RefreshCoordinator.providerIDs {
            fetchers[id] = { [unowned self] completion in
                self.calls[id, default: 0] += 1
                self.pending[id] = completion
            }
        }
        return RefreshCoordinator(defaults: defaults, now: { self.clock }, fetchers: fetchers)
    }

    private func refresh(_ coordinator: RefreshCoordinator, _ trigger: RefreshTrigger = .timer,
                         interval: TimeInterval = 60, codex: Bool = true) {
        coordinator.refresh(trigger: trigger, interval: interval, showCodex: codex)
    }

    private func finish(_ id: String, _ result: Result<ProviderUsage, UsageError>) {
        let completion = pending.removeValue(forKey: id)!
        completion(result)
    }

    private func success(_ id: String, percent: Double = 81) -> Result<ProviderUsage, UsageError> {
        .success(ProviderUsage(id: id, title: id.capitalized, plan: "Test", rows: [
            UsageRow(title: "Session", percent: percent, resetsAt: nil, isSession: true, isActive: true)
        ], credits: nil))
    }

    func testEveryTriggerRespectsPauseAndCodexKeepsRefreshing() {
        let c = make()
        refresh(c, .launch)
        finish("claude", .failure(.rateLimited(retryAfter: clock.addingTimeInterval(3600))))
        finish("codex", success("codex"))
        let blocked = c.schedule(for: "claude")!
        var changes = 0
        c.onChange = { changes += 1 }
        for trigger in RefreshTrigger.allCases {
            clock.addTimeInterval(60)
            refresh(c, trigger)
            XCTAssertEqual(calls["claude"], 1, "\(trigger)")
            XCTAssertEqual(c.schedule(for: "claude"), blocked)
            XCTAssertEqual(c.statuses["claude"], .paused(until: blocked.blockedUntil!))
            finish("codex", success("codex"))
        }
        XCTAssertEqual(calls["codex"], 1 + RefreshTrigger.allCases.count)
        XCTAssertGreaterThanOrEqual(changes, RefreshTrigger.allCases.count)
    }

    func testFallbackStepsSaturateAndOnlyOwnSuccessResets() {
        let c = make()
        refresh(c)
        for delay in [300.0, 600, 1200, 1800, 1800] {
            finish("claude", .failure(.rateLimited(retryAfter: nil)))
            let before = c.schedule(for: "claude")!
            XCTAssertEqual(before.blockedUntil, clock.addingTimeInterval(delay))
            finish("codex", success("codex"))
            for trigger in RefreshTrigger.allCases { refresh(c, trigger) }
            XCTAssertEqual(c.schedule(for: "claude"), before)
            clock.addTimeInterval(delay - 1)
            refresh(c)
            XCTAssertNil(pending["claude"])
            clock.addTimeInterval(1)
            refresh(c)
            XCTAssertNotNil(pending["claude"])
        }
        XCTAssertEqual(c.schedule(for: "claude")?.backoffStep, 4)
        finish("claude", success("claude"))
        XCTAssertEqual(c.schedule(for: "claude")?.backoffStep, 0)
        XCTAssertNil(c.schedule(for: "claude")?.blockedUntil)
        XCTAssertNil(c.errors["claude"])
        clock.addTimeInterval(300)
        refresh(c)
        finish("claude", .failure(.rateLimited(retryAfter: nil)))
        XCTAssertEqual(c.schedule(for: "claude")?.blockedUntil, clock.addingTimeInterval(300))
    }

    func testLongServerPauseNotCappedAndShortPauseStillRespectsInterval() {
        let c = make()
        refresh(c, codex: false)
        let until = clock.addingTimeInterval(7200)
        finish("claude", .failure(.rateLimited(retryAfter: until)))
        clock.addTimeInterval(1800)
        refresh(c, .manual, codex: false)
        XCTAssertEqual(calls["claude"], 1)
        XCTAssertEqual(c.schedule(for: "claude")?.blockedUntil, until)
        clock = until
        refresh(c, codex: false)
        finish("claude", .failure(.rateLimited(retryAfter: clock.addingTimeInterval(10))))
        XCTAssertEqual(c.statuses["claude"], .paused(until: clock.addingTimeInterval(300)))
        clock.addTimeInterval(10)
        refresh(c, .manual, codex: false)
        XCTAssertEqual(calls["claude"], 2)
        XCTAssertEqual(c.statuses["claude"], .scheduled(after: clock.addingTimeInterval(290)))
    }

    func testPastServerDateUsesFallback() {
        let c = make()
        refresh(c, codex: false)
        finish("claude", .failure(.rateLimited(retryAfter: clock.addingTimeInterval(-1))))
        XCTAssertEqual(c.schedule(for: "claude")?.blockedUntil, clock.addingTimeInterval(300))
    }

    func testEveryTriggerRespectsInFlightEvenBeyondIntervalAndResultsPublishSeparately() {
        let c = make()
        var published: [[String]] = []
        c.onSnapshotChange = { published.append(c.snapshot.providers.map(\.id)) }
        refresh(c)
        clock.addTimeInterval(1000)
        for trigger in RefreshTrigger.allCases { refresh(c, trigger) }
        XCTAssertEqual(calls, ["claude": 1, "codex": 1])
        finish("codex", success("codex"))
        XCTAssertTrue(c.hasRequestsInFlight)
        XCTAssertEqual(c.snapshot.providers.map(\.id), ["codex"])
        XCTAssertEqual(published.last, ["codex"])
        refresh(c)
        XCTAssertEqual(calls["codex"], 2)
        XCTAssertEqual(calls["claude"], 1)
        finish("claude", success("claude"))
        XCTAssertEqual(c.snapshot.providers.map(\.id), ["claude", "codex"])
    }

    func testEveryTriggerRespectsMinimumAndLongerSetting() {
        let c = make()
        refresh(c, codex: false)
        finish("claude", success("claude"))
        clock.addTimeInterval(299)
        for trigger in RefreshTrigger.allCases { refresh(c, trigger, codex: false) }
        XCTAssertEqual(calls["claude"], 1)
        XCTAssertNil(c.errors["claude"])
        clock.addTimeInterval(1)
        refresh(c, codex: false)
        finish("claude", success("claude"))
        clock.addTimeInterval(300)
        refresh(c, .settings, interval: 900, codex: false)
        XCTAssertEqual(calls["claude"], 2)
        clock.addTimeInterval(600)
        refresh(c, interval: 900, codex: false)
        XCTAssertEqual(calls["claude"], 3)
    }

    func testRestartRestoresPauseBeforeFirstRefreshAndRetainsStepAfterExpiry() {
        var c = make()
        refresh(c, codex: false)
        finish("claude", .failure(.rateLimited(retryAfter: nil)))
        let until = c.schedule(for: "claude")!.blockedUntil!
        clock.addTimeInterval(60)
        c = make()
        refresh(c, .launch, codex: false)
        XCTAssertEqual(calls["claude"], 1)
        XCTAssertEqual(c.statuses["claude"], .paused(until: until))
        XCTAssertNil(c.snapshot.lastSuccessAt)
        XCTAssertFalse(c.hasRequestsInFlight)
        clock = until
        c = make()
        refresh(c, .launch, codex: false)
        XCTAssertEqual(calls["claude"], 2)
        finish("claude", .failure(.rateLimited(retryAfter: nil)))
        XCTAssertEqual(c.schedule(for: "claude")?.blockedUntil, clock.addingTimeInterval(600))
        clock.addTimeInterval(600)
        refresh(c, codex: false)
        finish("claude", success("claude"))
        c = make()
        XCTAssertEqual(c.schedule(for: "claude")?.backoffStep, 0)
        XCTAssertNil(c.schedule(for: "claude")?.blockedUntil)
    }

    func testRestartRetainsLastStartAndDoesNotRestoreInFlight() {
        var c = make()
        refresh(c, codex: false)
        clock.addTimeInterval(1)
        c = make()
        refresh(c, .launch, codex: false)
        XCTAssertFalse(c.hasRequestsInFlight)
        XCTAssertEqual(calls["claude"], 1)
        clock.addTimeInterval(299)
        refresh(c, codex: false)
        XCTAssertEqual(calls["claude"], 2)
    }

    func testFailurePreservesLastSuccessAndOrdinaryWaitDoesNotMakeDataStale() {
        let c = make()
        refresh(c, codex: false)
        finish("claude", success("claude"))
        let successAt = c.snapshot.lastSuccessAt
        clock.addTimeInterval(60)
        refresh(c, .manual, codex: false)
        XCTAssertTrue(c.errors.isEmpty)
        XCTAssertEqual(c.snapshot.lastSuccessAt, successAt)
        clock.addTimeInterval(240)
        refresh(c, codex: false)
        finish("claude", .failure(.rateLimited(retryAfter: nil)))
        XCTAssertEqual(c.snapshot.providers.first?.rows.first?.percent, 81)
        XCTAssertEqual(c.snapshot.lastSuccessAt, successAt)
        XCTAssertNotNil(c.errors["claude"])
    }

    func testHiddenCodexCompletionDoesNotRestoreCardButPersistsPause() {
        let c = make()
        refresh(c)
        refresh(c, .visibility, codex: false)
        finish("codex", .failure(.rateLimited(retryAfter: nil)))
        XCTAssertNil(c.errors["codex"])
        XCTAssertNil(c.statuses["codex"])
        XCTAssertFalse(c.snapshot.providers.contains { $0.id == "codex" })
        refresh(c, .visibility)
        XCTAssertEqual(calls["codex"], 1)
        XCTAssertNotNil(c.statuses["codex"])
        XCTAssertNotNil(c.errors["codex"])
        clock.addTimeInterval(300)
        refresh(c)
        refresh(c, .visibility, codex: false)
        finish("codex", success("codex"))
        XCTAssertFalse(c.snapshot.providers.contains { $0.id == "codex" })
    }

    func testCodexRateLimitDoesNotBlockClaude() {
        let c = make()
        refresh(c)
        finish("claude", success("claude"))
        finish("codex", .failure(.rateLimited(retryAfter: clock.addingTimeInterval(3600))))
        clock.addTimeInterval(300)
        refresh(c, .menu)
        XCTAssertEqual(calls["claude"], 2)
        XCTAssertEqual(calls["codex"], 1)
    }

    func testSynchronousFailureAndMalformedStoredStateDoNotStickInFlight() {
        defaults.set(Data("broken".utf8), forKey: "refreshSchedule.v1.claude")
        var requests = 0
        let c = RefreshCoordinator(defaults: defaults, now: { self.clock }, fetchers: [
            "claude": { completion in requests += 1; completion(.failure(.notLoggedIn("Claude"))) }
        ])
        refresh(c, codex: false)
        XCTAssertFalse(c.hasRequestsInFlight)
        XCTAssertNotNil(c.errors["claude"])
        refresh(c, .manual, codex: false)
        XCTAssertEqual(requests, 1)
        clock.addTimeInterval(300)
        refresh(c, codex: false)
        XCTAssertEqual(requests, 2)
    }

    func testTimerUsesEarliestProviderDeadlineWithoutRoundingToGlobalTicks() {
        let c = make()
        refresh(c, interval: 120)
        XCTAssertNil(c.nextRefreshAt) // Both providers are in flight.
        finish("claude", success("claude"))
        finish("codex", success("codex"))
        XCTAssertEqual(c.nextRefreshAt, clock.addingTimeInterval(120))
        clock.addTimeInterval(120)
        refresh(c, interval: 120)
        finish("codex", success("codex"))
        clock.addTimeInterval(120)
        refresh(c, interval: 120)
        finish("codex", success("codex"))
        XCTAssertEqual(c.nextRefreshAt, clock.addingTimeInterval(60)) // Claude at minute 5.
        clock.addTimeInterval(60)
        refresh(c, interval: 120)
        XCTAssertEqual(calls["claude"], 2)
        XCTAssertEqual(calls["codex"], 3)
    }
}
