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

    var hottestPercent: Double { rows.map(\.percent).max() ?? 0 }
}

/// Everything the status item needs to render.
struct CombinedSnapshot: Codable, Hashable {
    let providers: [ProviderUsage]
    let fetchedAt: Date

    var headlinePercent: Double { providers.map(\.hottestPercent).max() ?? 0 }
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
