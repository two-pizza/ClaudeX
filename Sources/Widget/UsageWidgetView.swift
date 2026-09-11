import WidgetKit
import SwiftUI

/// Shared look for all three sizes, built from one provider card.
/// Small: the provider closest to running out, as a ring. Medium: both
/// providers side by side, session and weekly. Large: the same with the
/// per-model windows spelled out.
struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var payload: SharedStore.Payload? { entry.payload }

    var body: some View {
        switch payload {
        case .none:
            EmptyStateView(message: "Open ClaudeX to load usage")
        case .some(let payload) where payload.isEmpty:
            EmptyStateView(message: payload.errors.values.first ?? "No usage data yet")
        case .some(let payload):
            switch family {
            case .systemSmall: SmallView(payload: payload)
            case .systemLarge: CardsView(payload: payload, detailed: true)
            default:           CardsView(payload: payload, detailed: false)
            }
        }
    }
}

// MARK: - Small: the provider closest to running out

private struct SmallView: View {
    let payload: SharedStore.Payload

    private var tightest: ProviderUsage? {
        payload.snapshot.providers.min(by: { $0.headlineRemaining < $1.headlineRemaining })
    }

    var body: some View {
        if let provider = tightest {
            let stale = payload.errors[provider.id] != nil
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(provider.title).font(.caption).fontWeight(.semibold)
                    Spacer()
                    if stale { StaleBadge() }
                }
                Spacer(minLength: 0)
                Ring(remaining: provider.headlineRemaining)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Text("session left")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let session = provider.sessionRow, let reset = ResetText.make(session) {
                    Text(reset).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .opacity(stale ? 0.55 : 1)
        }
    }
}

private struct Ring: View {
    let remaining: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(remaining, 0), 100) / 100)
                .stroke(UsageColor.forRemaining(remaining), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(remaining))%")
                .font(.system(.title3, design: .rounded)).fontWeight(.semibold)
                .monospacedDigit()
        }
        .frame(width: 62, height: 62)
    }
}

// MARK: - Medium and large: one card per provider

private struct CardsView: View {
    let payload: SharedStore.Payload
    let detailed: Bool

    var body: some View {
        let providers = payload.snapshot.providers
        if detailed {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(providers, id: \.id) { provider in
                    ProviderCard(provider: provider, error: payload.errors[provider.id], detailed: true)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(providers, id: \.id) { provider in
                    ProviderCard(provider: provider, error: payload.errors[provider.id], detailed: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ProviderCard: View {
    let provider: ProviderUsage
    let error: String?
    let detailed: Bool

    private var stale: Bool { error != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.title).font(.caption).fontWeight(.semibold)
                Spacer(minLength: 4)
                if stale { StaleBadge() } else {
                    Text(provider.plan).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if let session = provider.sessionRow {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(session.remaining))%")
                        .font(.system(.title2, design: .rounded)).fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(UsageColor.forRemaining(session.remaining))
                    Text(session.isSession ? "session left" : "\(session.title.lowercased()) left")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Bar(remaining: session.remaining)
                if let reset = ResetText.make(session) {
                    Text(reset).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }

            if let weekly = provider.weeklyRow {
                LimitLine(row: weekly)
            }
            if detailed {
                ForEach(provider.modelRows, id: \.self) { row in
                    LimitLine(row: row).padding(.leading, 8)
                }
            }

            Text(footer)
                .font(.caption2)
                .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
        }
        .opacity(stale ? 0.6 : 1)
    }

    private var footer: String {
        let when = RelativeStamp.make(provider.fetchedAt)
        return stale ? "Stale · last update \(when)" : "Updated \(when)"
    }
}

private struct LimitLine: View {
    let row: UsageRow

    var body: some View {
        HStack(spacing: 4) {
            Text(row.title).font(.caption2).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(Int(row.remaining))% left")
                .font(.caption2).fontWeight(.medium).monospacedDigit()
                .foregroundStyle(UsageColor.forRemaining(row.remaining))
        }
    }
}

private struct Bar: View {
    let remaining: Double

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(remaining, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    // Anything left keeps a visible sliver; nothing left draws nothing.
                    Capsule()
                        .fill(UsageColor.forRemaining(remaining))
                        .frame(width: max(geometry.size.width * fraction, 5))
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Shared pieces

private struct StaleBadge: View {
    var body: some View {
        Text("STALE")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.orange)
    }
}

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
    static func forRemaining(_ remaining: Double) -> Color {
        switch RemainingLevel(remaining: remaining) {
        case .critical: return .red
        case .low:      return .orange
        case .fine:     return .blue
        }
    }
}

enum RelativeStamp {
    static func make(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:   return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        default:      return "\(seconds / 3600) h ago"
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
