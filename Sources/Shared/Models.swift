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

    /// The 5-hour window - the number that runs out first in practice.
    var sessionRow: UsageRow? { rows.first(where: \.isSession) ?? rows.first }
    /// The overall weekly window ("All models" for Claude, "Weekly" for Codex).
    var weeklyRow: UsageRow? { rows.first(where: { !$0.isSession }) }
    /// Per-model weekly windows, collapsed behind "Model limits" in the panel.
    var modelRows: [UsageRow] {
        guard let weeklyRow else { return [] }
        return rows.filter { !$0.isSession && $0 != weeklyRow }
    }

    /// What is left of the session - the headline number for this provider.
    var headlineRemaining: Double { sessionRow?.remaining ?? tightestRemaining }
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
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let tool): return "\(tool) is not logged in"
        case .keychainDenied:        return "Keychain access denied - allow it in the dialog"
        case .malformedAuth:         return "Could not parse stored credentials"
        case .unauthorized(let fix): return "Token rejected - \(fix)"
        case .http(let code):        return "Server returned \(code)"
        case .transport(let m):      return m
        case .malformedResponse:     return "Could not parse server response"
        }
    }
}
#endif
