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

/// Everything the status item needs to render.
struct CombinedSnapshot: Codable, Hashable {
    let providers: [ProviderUsage]
    /// When the last refresh cycle ran, successful or not.
    let fetchedAt: Date

    var headlinePercent: Double { providers.map(\.hottestPercent).max() ?? 0 }

    /// Time of the newest successful fetch - what the "Updated" line means.
    /// A provider whose own fetch failed is marked stale separately, so a
    /// fresh Claude next to a stale Codex reads correctly on both counts.
    var lastSuccessAt: Date {
        providers.compactMap(\.fetchedAt).max() ?? fetchedAt
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
        case .rateLimited:           return "Rate limited - retrying later"
        case .malformedResponse:     return "Could not parse server response"
        }
    }
}
#endif
