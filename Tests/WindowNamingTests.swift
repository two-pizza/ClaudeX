import XCTest
@testable import ClaudeXPolicy

final class WindowNamingTests: XCTestCase {
    func testCodexWindowsAreNamedByLength() {
        XCTAssertEqual(CodexWindowName.title(seconds: 5 * 3600), "Current session")
        XCTAssertTrue(CodexWindowName.isSession(seconds: 5 * 3600))
        XCTAssertEqual(CodexWindowName.title(seconds: 7 * 86400), "Weekly")
        // Codex Go: the window is a month, not a week.
        XCTAssertEqual(CodexWindowName.title(seconds: 30 * 86400), "Monthly")
        XCTAssertEqual(CodexWindowName.title(seconds: 31 * 86400), "Monthly")
        XCTAssertFalse(CodexWindowName.isSession(seconds: 30 * 86400))
        XCTAssertEqual(CodexWindowName.title(seconds: 14 * 86400), "14-day window")
        XCTAssertEqual(CodexWindowName.title(seconds: 12 * 3600), "12-hour window")
        XCTAssertEqual(CodexWindowName.title(seconds: 5 * 86400), "5-day window")
        XCTAssertEqual(CodexWindowName.title(seconds: 25 * 86400), "Monthly")
        XCTAssertEqual(CodexWindowName.title(seconds: 35 * 86400), "Monthly")
        XCTAssertEqual(CodexWindowName.title(seconds: 90 * 86400), "90-day window")
        XCTAssertEqual(CodexWindowName.title(seconds: 0), "Window")
    }

    func testResetFarAwayShowsTheDate() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_794_589_200) // 2026-11-13 17:00 UTC, Friday
        let soon = UsageRow(title: "Weekly", percent: 60, resetsAt: now.addingTimeInterval(2 * 86400),
                            isSession: false, isActive: true)
        XCTAssertEqual(ResetText.make(soon, now: now, timeZone: utc), "resets Sun 17:00")
        let far = UsageRow(title: "Monthly", percent: 96, resetsAt: now.addingTimeInterval(12 * 86400),
                           isSession: false, isActive: true)
        XCTAssertEqual(ResetText.make(far, now: now, timeZone: utc), "resets Nov 25 17:00")
        let session = UsageRow(title: "Current session", percent: 31, resetsAt: now.addingTimeInterval(4 * 3600 + 18 * 60),
                               isSession: true, isActive: true)
        let edge = UsageRow(title: "Weekly", percent: 1, resetsAt: now.addingTimeInterval(6 * 86400 - 1),
                            isSession: false, isActive: true)
        XCTAssertEqual(ResetText.make(edge, now: now, timeZone: utc), "resets Thu 16:59")
        let atSix = UsageRow(title: "Weekly", percent: 1, resetsAt: now.addingTimeInterval(6 * 86400),
                             isSession: false, isActive: true)
        XCTAssertEqual(ResetText.make(atSix, now: now, timeZone: utc), "resets Nov 19 17:00")
        let nextYear = UsageRow(title: "Monthly", percent: 1, resetsAt: now.addingTimeInterval(50 * 86400),
                                isSession: false, isActive: true)
        XCTAssertEqual(ResetText.make(nextYear, now: now, timeZone: utc), "resets Jan 2 2027 17:00")
        XCTAssertEqual(ResetText.make(session, now: now, timeZone: utc), "resets in 4 h 18 min")
    }
}
