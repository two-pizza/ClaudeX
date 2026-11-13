import XCTest
@testable import ClaudeXPolicy

final class MenuBarSummaryTests: XCTestCase {
    private func row(_ title: String, _ percent: Double, session: Bool = false) -> UsageRow {
        UsageRow(title: title, percent: percent, resetsAt: nil, isSession: session, isActive: true)
    }
    private func provider(_ id: String, _ rows: [UsageRow]) -> ProviderUsage {
        ProviderUsage(id: id, title: id.capitalized, plan: "", rows: rows, credits: nil)
    }
    private var gleb: CombinedSnapshot {
        CombinedSnapshot(providers: [
            provider("claude", [row("Current session", 31, session: true), row("All models", 60), row("Fable", 21)]),
            provider("codex", [row("Monthly", 96)])
        ], fetchedAt: Date())
    }

    func testMostUsedIsTheOldBehaviour() {
        let s = MenuBarSummary.make(snapshot: gleb, mode: .mostUsed, ring: .all)
        XCTAssertEqual(s.parts, ["60%", "96%"])
        XCTAssertEqual(s.ringPercent, 96)
        XCTAssertEqual(s.ringPercent, gleb.headlinePercent)
    }

    func testSessionPreferredWithClaudeRing() {
        let s = MenuBarSummary.make(snapshot: gleb, mode: .sessionPreferred, ring: .claude)
        XCTAssertEqual(s.parts, ["31%", "96%"])
        XCTAssertEqual(s.ringPercent, 31)
        XCTAssertEqual(s.toolTip, """
            Claude: Current session 31% (shown) · All models 60% · Fable 21%
            Codex: Monthly 96% (shown) - no session window
            """)
        XCTAssertEqual(MenuBarSummary.make(snapshot: gleb, mode: .sessionPreferred, ring: .all).ringPercent, 96)
        XCTAssertEqual(MenuBarSummary.make(snapshot: gleb, mode: .mostUsed, ring: .codex).ringPercent, 96)
    }

    func testZeroSessionStaysZero() {
        let snap = CombinedSnapshot(providers: [
            provider("claude", [row("Current session", 0, session: true), row("All models", 60)])
        ], fetchedAt: Date())
        let s = MenuBarSummary.make(snapshot: snap, mode: .sessionPreferred, ring: .all)
        XCTAssertEqual(s.parts, ["0%"])
        XCTAssertEqual(s.ringPercent, 0)
    }

    func testSeveralSessionsTakeTheBusiest() {
        let p = provider("claude", [row("A", 10, session: true), row("B", 40, session: true), row("Weekly", 90)])
        XCTAssertEqual(p.shownRow(.sessionPreferred)?.percent, 40)
        XCTAssertEqual(p.shownRow(.mostUsed)?.percent, 90)
    }

    func testEmptyRowsAreNoDataNotZero() {
        let snap = CombinedSnapshot(providers: [provider("claude", []), provider("codex", [row("Weekly", 20)])],
                                    fetchedAt: Date())
        let s = MenuBarSummary.make(snapshot: snap, mode: .sessionPreferred, ring: .claude)
        XCTAssertEqual(s.parts, ["—", "20%"])
        XCTAssertNil(s.ringPercent)
        XCTAssertTrue(s.toolTip.hasPrefix("Claude: no data"))
    }

    func testHiddenRingProviderFallsBackToAll() {
        let snap = CombinedSnapshot(providers: [provider("claude", [row("All models", 60)])], fetchedAt: Date())
        XCTAssertEqual(MenuBarSummary.make(snapshot: snap, mode: .mostUsed, ring: .codex).ringPercent, 60)
    }
}
