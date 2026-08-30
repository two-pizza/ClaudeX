import WidgetKit
import SwiftUI

/// The widget never fetches: it renders whatever the app last wrote into the
/// shared container (see SharedStore). Reloads are driven by the app calling
/// WidgetCenter after each successful refresh; the timeline below is only a
/// safety net for when the app is not running.
struct UsageProvider: TimelineProvider {

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), payload: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), payload: SharedStore.read() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: Date(), payload: SharedStore.read())
        // Ask to be woken in 15 minutes. If the app is alive it will have
        // reloaded us long before that; if it is not, the numbers are stale
        // anyway and the view says so.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let payload: SharedStore.Payload?
}

@main
struct ClaudeXWidgetBundle: WidgetBundle {
    var body: some Widget { UsageWidget() }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "me.andrey.ClaudeX.usage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("ClaudeX")
        .description("Claude and Codex usage limits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview data

extension SharedStore.Payload {
    /// Shown in the widget gallery and while the real snapshot is missing.
    static var preview: SharedStore.Payload {
        let now = Date()
        let claude = ProviderUsage(
            id: "claude", title: "Claude", plan: "Max (5x)",
            rows: [
                UsageRow(title: "Current session", percent: 31,
                         resetsAt: now.addingTimeInterval(3 * 3600), isSession: true, isActive: true),
                UsageRow(title: "All models", percent: 23,
                         resetsAt: now.addingTimeInterval(4 * 86400), isSession: false, isActive: true),
                UsageRow(title: "Fable", percent: 15,
                         resetsAt: now.addingTimeInterval(4 * 86400), isSession: false, isActive: false),
            ],
            credits: nil)
        let codex = ProviderUsage(
            id: "codex", title: "Codex", plan: "Plus",
            rows: [
                UsageRow(title: "Current session", percent: 2,
                         resetsAt: now.addingTimeInterval(3600), isSession: true, isActive: true),
                UsageRow(title: "Weekly", percent: 40,
                         resetsAt: now.addingTimeInterval(4 * 86400), isSession: false, isActive: true),
            ],
            credits: nil)
        return SharedStore.Payload(
            snapshot: CombinedSnapshot(providers: [claude, codex], fetchedAt: now),
            errors: [:], writtenAt: now)
    }
}
