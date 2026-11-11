import Foundation

/// Presentation content shared by the AppKit renderer and offline tests.
enum UsagePanelElement: Equatable {
    case header(title: String, trailing: String)
    case row(UsageRow)
    case note(String)
    case warning(String)
    case footer(String)
    case divider
}

enum UsagePanelContent {
    static func make(snapshot: CombinedSnapshot, errors: [String: String],
                     statuses: [String: RefreshStatus], now: Date) -> [UsagePanelElement] {
        var items: [UsagePanelElement] = []
        for id in RefreshCoordinator.providerIDs {
            let provider = snapshot.providers.first { $0.id == id }
            guard provider != nil || errors[id] != nil || statuses[id] != nil else { continue }
            if !items.isEmpty { items.append(.divider) }
            items.append(.header(title: provider?.title ?? id.capitalized, trailing: provider?.plan ?? ""))
            if let provider {
                // Credits are kept in the snapshot but not shown: the panel stays
                // limited to the windows that can stop you.
                items.append(contentsOf: provider.rows.map { .row($0) })
                if errors[id] != nil {
                    let when = provider.fetchedAt.map { relativeStamp($0, now: now) } ?? "earlier"
                    items.append(.warning("Stale · last update \(when)"))
                }
            } else {
                items.append(.note("No data yet"))
            }
            // Only a rate-limit pause explains numbers that stop moving; the
            // next scheduled refresh lives in the status item tooltip.
            if let status = statuses[id], case .paused = status {
                items.append(.note(status.text(now: now)))
            }
            if let error = errors[id] {
                // A paused status already names rate limiting. Keep other
                // failures visible while a refresh is running or scheduled.
                if case .paused? = statuses[id] {} else { items.append(.note(error)) }
            }
        }
        if items.isEmpty { items.append(.note("No data yet")) }
        // Fresh data needs no timestamp; once a provider fails, say how old
        // the newest numbers are.
        if !errors.isEmpty, let success = snapshot.lastSuccessAt {
            items.append(.footer("Updated \(relativeStamp(success, now: now))"))
        }
        return items
    }

    static func relativeStamp(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        default: return "\(seconds / 3600) h ago"
        }
    }
}
