import XCTest
@testable import ClaudeXPolicy

final class UsagePanelContentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testColdStartPausedHasExplanationAndNoFalseUpdatedFooter() {
        let snapshot = CombinedSnapshot(providers: [], fetchedAt: now)
        let items = UsagePanelContent.make(snapshot: snapshot,
            errors: ["claude": "Last request was rate limited"],
            statuses: ["claude": .paused(until: now.addingTimeInterval(600))], now: now)
        XCTAssertTrue(items.contains(.note("No data yet")))
        XCTAssertTrue(items.contains { if case .note(let text) = $0 { return text.contains("Paused until") }; return false })
        XCTAssertFalse(items.contains { if case .footer = $0 { return true }; return false })
        XCTAssertNil(snapshot.lastSuccessAt)
    }

    func testWaitAndRefreshingAreNotErrorsAndSuccessFooterIsPreserved() {
        let usage = ProviderUsage(id: "claude", title: "Claude", plan: "Test", rows: [],
                                  credits: nil, fetchedAt: now.addingTimeInterval(-120))
        let snapshot = CombinedSnapshot(providers: [usage], fetchedAt: now)
        for status in [RefreshStatus.scheduled(after: now.addingTimeInterval(60)), .refreshing] {
            let items = UsagePanelContent.make(snapshot: snapshot, errors: [:], statuses: ["claude": status], now: now)
            XCTAssertTrue(items.contains(.note(status.text(now: now))))
            XCTAssertTrue(items.contains(.footer("Updated 2 min ago")))
            XCTAssertFalse(items.contains { if case .warning = $0 { return true }; return false })
        }
    }

    func testFailureShowsStaleAndOlderSuccessDoesNotBecomeFresh() {
        let usage = ProviderUsage(id: "claude", title: "Claude", plan: "Test", rows: [],
                                  credits: nil, fetchedAt: now.addingTimeInterval(-900))
        let snapshot = CombinedSnapshot(providers: [usage], fetchedAt: now)
        let items = UsagePanelContent.make(snapshot: snapshot, errors: ["claude": "Server returned 500"],
                                         statuses: [:], now: now)
        XCTAssertTrue(items.contains(.warning("Stale · last update 15 min ago")))
        XCTAssertTrue(items.contains(.footer("Updated 15 min ago")))
    }

    func testEffectiveIntervalsAndHiddenCodex() {
        XCTAssertEqual(RefreshCoordinator.intervalSummary(selected: 60, showCodex: true),
                       "Claude: every 5 min · Codex: every 1 min")
        XCTAssertEqual(RefreshCoordinator.intervalSummary(selected: 300, showCodex: true),
                       "Claude: every 5 min · Codex: every 5 min")
        XCTAssertEqual(RefreshCoordinator.intervalSummary(selected: 900, showCodex: true),
                       "Claude: every 15 min · Codex: every 15 min")
        XCTAssertEqual(RefreshCoordinator.intervalSummary(selected: 60, showCodex: false), "Claude: every 5 min")
        XCTAssertEqual(RefreshCoordinator.effectiveInterval(for: "claude", selected: .nan), 300)
    }

    func testDeadlineIncludesDateAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 59))!
        XCTAssertEqual(RefreshStatus.paused(until: today.addingTimeInterval(120)).text(now: today, calendar: calendar),
                       "Paused until Oct 2 00:01 (rate limited)")
    }

    func testOldSnapshotWithoutProviderTimestampHasNoInventedSuccess() throws {
        let json = """
        {"providers":[{"id":"claude","title":"Claude","plan":"Test","rows":[]}],"fetchedAt":1000}
        """
        let snapshot = try JSONDecoder().decode(CombinedSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.lastSuccessAt)
    }
}
