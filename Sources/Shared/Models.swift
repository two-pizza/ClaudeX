import Foundation

/// One limit bar: a usage window with its reset time.
struct UsageRow: Codable, Hashable {
    let title: String
    let percent: Double
    let resetsAt: Date?
    /// Session windows render a relative reset ("resets in 4 h 55 min"),
    /// weekly windows an absolute one ("resets Fri 19:00").
    let isSession: Bool
    let isActive: Bool
}

/// Usage of one provider (Claude or Codex) as shown in the panel.
struct ProviderUsage: Codable, Hashable {
    let id: String
    let title: String
    let plan: String
    let rows: [UsageRow]
    let credits: String?
    /// When these numbers were last fetched successfully. Tracked per provider:
    /// a failed fetch keeps the old numbers AND their old time, so the panel
    /// never says "just now" over data it did not get. Optional so a snapshot
    /// written by 1.2.1 still decodes in the widget.
    var fetchedAt: Date? = nil

    var hottestPercent: Double { rows.map(\.percent).max() ?? 0 }
}

/// Which window stands for a provider in the menu bar.
enum MenuBarWindow: String, CaseIterable {
    /// The busiest window - the one closest to its limit.
    case mostUsed
    /// The 5-hour session when the plan has one, otherwise the busiest window.
    case sessionPreferred
}

/// Which providers the ring summarises.
enum RingSource: String, CaseIterable {
    case all, claude, codex
}

extension ProviderUsage {
    /// The window shown for this provider; nil when there are no windows (no data).
    func shownRow(_ mode: MenuBarWindow) -> UsageRow? {
        let busiest = { (rows: [UsageRow]) in rows.max { $0.percent < $1.percent } }
        if mode == .sessionPreferred, let session = busiest(rows.filter(\.isSession)) {
            return session
        }
        return busiest(rows)
    }
}

/// Everything the status item shows, computed in one place so the ring,
/// the numbers and the tooltip never disagree about which window they mean.
struct MenuBarSummary: Equatable {
    /// nil: no data for the ring's providers - a gray empty ring.
    let ringPercent: Double?
    /// One number per provider, "—" where a provider has no windows.
    let parts: [String]
    /// Every window of every provider, the shown one marked.
    let toolTip: String

    static func make(snapshot: CombinedSnapshot, mode: MenuBarWindow, ring: RingSource) -> MenuBarSummary {
        let providers = snapshot.providers
        let parts = providers.map { provider in
            provider.shownRow(mode).map { String(format: "%.0f%%", $0.percent) } ?? "—"
        }
        let lines = providers.map { provider -> String in
            guard !provider.rows.isEmpty else { return "\(provider.title): no data" }
            let shown = provider.shownRow(mode)
            let windows = provider.rows.map { row in
                "\(row.title) \(Int(row.percent))%" + (row == shown ? " (shown)" : "")
            }.joined(separator: " · ")
            let noSession = mode == .sessionPreferred && !provider.rows.contains(where: \.isSession)
            return "\(provider.title): \(windows)" + (noSession ? " - no session window" : "")
        }
        // A ring source whose provider is hidden or missing falls back to all.
        let selected = providers.filter { ring == .all || $0.id == ring.rawValue }
        let ringProviders = selected.isEmpty ? providers : selected
        let ringPercent = ringProviders.compactMap { $0.shownRow(mode)?.percent }.max()
        return MenuBarSummary(ringPercent: ringPercent, parts: parts,
                              toolTip: lines.joined(separator: "\n"))
    }
}

/// Codex does not name its windows; they are named here by length.
enum CodexWindowName {
    static func title(seconds: Double) -> String {
        let days = seconds / 86400
        switch seconds {
        case ...0:              return "Window"
        case ...(6 * 3600):     return "Current session"
        case ..<86400:          return "\(Int((seconds / 3600).rounded()))-hour window"
        case (86400 * 6)...(86400 * 8): return "Weekly"
        case (86400 * 25)...(86400 * 35): return "Monthly"
        default:                return "\(Int(days.rounded()))-day window"
        }
    }
    static func isSession(seconds: Double) -> Bool { seconds > 0 && seconds <= 6 * 3600 }
}

/// "resets in 4 h 18 min" for a session, "resets Sun 17:59" within a week,
/// "resets Nov 25 17:45" further out - a bare weekday would read as this week.
enum ResetText {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = format
        return f
    }
    private static let weekdayTime = formatter("EEE HH:mm")
    private static let dateTime = formatter("MMM d HH:mm")
    private static let yearDateTime = formatter("MMM d yyyy HH:mm")

    static func make(_ row: UsageRow, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let resetsAt = row.resetsAt else { return nil }
        let seconds = max(0, resetsAt.timeIntervalSince(now))
        if row.isSession {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "resets in \(hours) h \(minutes) min" : "resets in \(minutes) min"
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f: DateFormatter
        if seconds < 6 * 86400 { f = weekdayTime }
        else if calendar.component(.year, from: resetsAt) != calendar.component(.year, from: now) { f = yearDateTime }
        else { f = dateTime }
        f.timeZone = timeZone
        return "resets \(f.string(from: resetsAt))"
    }
}

/// Everything the status item needs to render.
struct CombinedSnapshot: Codable, Hashable {
    let providers: [ProviderUsage]
    /// When the last refresh cycle ran, successful or not.
    let fetchedAt: Date

    var headlinePercent: Double { providers.map(\.hottestPercent).max() ?? 0 }

    /// Time of the newest successful fetch - what the "Updated" line means.
    /// A provider whose own fetch failed is marked stale separately, so a
    /// fresh Claude next to a stale Codex reads correctly on both counts.
    var lastSuccessAt: Date? {
        providers.compactMap(\.fetchedAt).max()
    }
}

#if !WIDGET_TARGET
enum UsageError: LocalizedError {
    case notLoggedIn(String)
    case keychainDenied
    case malformedAuth
    case unauthorized(String)
    case http(Int)
    case transport(String)
    case rateLimited(retryAfter: Date?)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let tool): return "\(tool) is not logged in"
        case .keychainDenied:        return "Keychain access denied - allow it in the dialog"
        case .malformedAuth:         return "Could not parse stored credentials"
        case .unauthorized(let fix): return "Token rejected - \(fix)"
        case .http(let code):        return "Server returned \(code)"
        case .transport(let m):      return m
        case .rateLimited:           return "Last request was rate limited"
        case .malformedResponse:     return "Could not parse server response"
        }
    }
}
#endif
