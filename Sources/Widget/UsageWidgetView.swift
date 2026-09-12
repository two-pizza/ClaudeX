import WidgetKit
import SwiftUI

/// Shared look for all three sizes. Small shows one ring, medium and large
/// show bars - a small widget has no room for legible labels next to bars.
struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var payload: SharedStore.Payload? { entry.payload }

    var body: some View {
        switch payload {
        case .none:
            EmptyStateView(message: "Open ClaudeX to load usage")
        case .some(let payload) where payload.isEmpty:
            EmptyStateView(message: payload.errors.values.first ?? "No usage data")
        case .some(let payload):
            switch family {
            case .systemSmall: SmallView(payload: payload)
            default:           BarsView(payload: payload, showAllRows: family == .systemLarge)
            }
        }
    }
}

// MARK: - Small: one ring for the hottest window

private struct SmallView: View {
    let payload: SharedStore.Payload

    private var hottest: (provider: ProviderUsage, row: UsageRow)? {
        payload.snapshot.providers
            .compactMap { provider in
                provider.rows.max(by: { $0.percent < $1.percent }).map { (provider, $0) }
            }
            .max(by: { $0.1.percent < $1.1.percent })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hottest {
                HStack {
                    Text(hottest.provider.title)
                        .font(.caption).fontWeight(.semibold)
                    Spacer()
                }
                Spacer(minLength: 0)
                Ring(percent: hottest.row.percent)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Text(hottest.row.title)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let reset = ResetText.make(hottest.row) {
                    Text(reset).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }
}

private struct Ring: View {
    let percent: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                .stroke(UsageColor.of(percent), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(percent))%")
                .font(.system(.title3, design: .rounded)).fontWeight(.semibold)
                .monospacedDigit()
        }
        .frame(width: 62, height: 62)
    }
}

// MARK: - Medium and large: bars

private struct BarsView: View {
    let payload: SharedStore.Payload
    let showAllRows: Bool

    /// A medium widget fits about four bars; large fits everything.
    private var providers: [ProviderUsage] {
        guard !showAllRows else { return payload.snapshot.providers }
        return payload.snapshot.providers.map { provider in
            ProviderUsage(id: provider.id, title: provider.title, plan: provider.plan,
                          rows: Array(provider.rows.prefix(2)), credits: provider.credits)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(providers, id: \.id) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(provider.title).font(.caption).fontWeight(.semibold)
                        Spacer()
                        Text(provider.plan).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(provider.rows, id: \.self) { row in
                        BarRow(row: row)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Updated \(payload.snapshot.fetchedAt, style: .relative) ago")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

private struct BarRow: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(row.title).font(.caption2).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(row.percent))%")
                    .font(.caption2).fontWeight(.medium).monospacedDigit()
                    .foregroundStyle(UsageColor.of(row.percent))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(UsageColor.of(row.percent))
                        // Keep a sliver visible at 1%, same as the menu bar panel.
                        .frame(width: max(geometry.size.width * min(max(row.percent, 0), 100) / 100, 5))
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Shared pieces

private struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.title2).foregroundStyle(.secondary)
            Text(message)
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum UsageColor {
    static func of(_ percent: Double) -> Color {
        switch percent {
        case 90...:   return .red
        case 75..<90: return .orange
        default:      return .blue
        }
    }
}

enum ResetText {
    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    static func make(_ row: UsageRow) -> String? {
        guard let resetsAt = row.resetsAt else { return nil }
        if row.isSession {
            let seconds = max(0, resetsAt.timeIntervalSinceNow)
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "resets in \(hours) h \(minutes) min" : "resets in \(minutes) min"
        }
        return "resets \(weekdayTime.string(from: resetsAt))"
    }
}
