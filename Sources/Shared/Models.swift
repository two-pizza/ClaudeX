import Foundation

/// One limit bar: a usage window with its reset time.
///
/// `percent` is what the provider reports - the share of the window already
/// used. Every view renders the complement, `remaining`, because "12% left"
/// is the number people act on; keeping the model in provider terms avoids
/// inverting twice.
struct UsageRow: Codable, Hashable {
    let title: String
    let percent: Double
    let resetsAt: Date?
    /// Session windows render a relative reset ("resets in 4 h 55 min"),
    /// weekly windows an absolute one ("resets Fri 19:00").
    let isSession: Bool
    let isActive: Bool

    var remaining: Double { max(0, min(100, 100 - percent)) }
}

/// Usage of one provider (Claude or Codex) as shown in the panel.
struct ProviderUsage: Codable, Hashable {
    let id: String
    let title: String
    let plan: String
    let rows: [UsageRow]
    let credits: String?
    /// When these numbers were fetched. Freshness is tracked per provider:
    /// one provider failing must not make the other look stale, and a
    /// failure must never make old numbers look fresh.
    var fetchedAt: Date = Date()

    /// One letter for the menu bar: "C 88% · X 68%".
    var shortLabel: String { id == "codex" ? "X" : "C" }

    /// The window that limits you right now. Claude marks it (`is_active`);
    /// otherwise it is whichever window has the least left. This is the
    /// headline of the card, the number in the menu bar and the ring.
    var headlineRow: UsageRow? {
        rows.first(where: \.isActive) ?? rows.min(by: { $0.remaining < $1.remaining })
    }
    /// "session left", "weekly left", "Fable left" - what the headline is about.
    var headlineLabel: String {
        guard let row = headlineRow else { return "" }
        if row.isSession { return "session left" }
        if row.title == "All models" || row.title == "Weekly" { return "weekly left" }
        return "\(row.title) left"
    }
    /// The other main windows - session and overall weekly - listed under the headline.
    var primaryRows: [UsageRow] {
        var out: [UsageRow] = []
        if let session = rows.first(where: \.isSession), session != headlineRow { out.append(session) }
        if let weekly = rows.first(where: { !$0.isSession && $0 != headlineRow }) { out.append(weekly) }
        return out
    }
    /// Per-model weekly windows, collapsed behind "Model limits" in the panel.
    var modelRows: [UsageRow] {
        rows.filter { $0 != headlineRow && !primaryRows.contains($0) }
    }
    /// The overall weekly window, for the tooltip.
    var weeklyRow: UsageRow? { rows.first(where: { !$0.isSession }) }

    /// What is left of the limiting window - the headline number for this provider.
    var headlineRemaining: Double { headlineRow?.remaining ?? 100 }
    /// The window closest to running out, across all of them.
    var tightestRemaining: Double { rows.map(\.remaining).min() ?? 100 }

    var hottestPercent: Double { rows.map(\.percent).max() ?? 0 }
}

/// Everything the status item needs to render.
struct CombinedSnapshot: Codable, Hashable {
    let providers: [ProviderUsage]
    /// When the last refresh cycle ran, successful or not. Per-provider
    /// freshness lives in `ProviderUsage.fetchedAt`.
    let fetchedAt: Date

    /// The tightest window of any provider - drives the ring colour.
    var tightestRemaining: Double { providers.map(\.tightestRemaining).min() ?? 100 }
    var headlinePercent: Double { providers.map(\.hottestPercent).max() ?? 0 }
}

/// Colour thresholds on what is left: red when almost gone, orange when
/// getting close, blue otherwise. Shared by the panel, the ring and the widget.
enum RemainingLevel {
    case fine, low, critical

    init(remaining: Double) {
        switch remaining {
        case ..<10: self = .critical
        case ..<25: self = .low
        default:    self = .fine
        }
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
    case rateLimited
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let tool): return "\(tool) is not logged in"
        case .keychainDenied:        return "Keychain access denied - allow it in the dialog"
        case .malformedAuth:         return "Could not parse stored credentials"
        case .unauthorized(let fix): return "Token rejected - \(fix)"
        case .http(let code):        return "Server returned \(code)"
        case .transport(let m):      return m
        case .rateLimited:           return "Rate limited - keeping the last numbers, retrying on the next tick"
        case .malformedResponse:     return "Could not parse server response"
        }
    }
}
#endif
