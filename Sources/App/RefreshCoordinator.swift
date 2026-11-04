import Foundation

enum RefreshTrigger: String, CaseIterable {
    case launch, timer, wake, clockChange, menu, manual, settings, visibility, diagnostic
}

enum RefreshStatus: Equatable {
    case refreshing
    case paused(until: Date)
    case scheduled(after: Date)

    func text(now: Date, calendar: Calendar = .current) -> String {
        func stamp(_ date: Date) -> String {
            let format = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d HH:mm"
            return Self.formatter(format: format, timeZone: calendar.timeZone).string(from: date)
        }
        switch self {
        case .refreshing: return "Refreshing…"
        case .paused(let date): return "Paused until \(stamp(date)) (rate limited)"
        case .scheduled(let date): return "Next refresh after \(stamp(date))"
        }
    }

    /// The status bar tooltip asks for this on every redraw; building a
    /// DateFormatter each time showed up as the hottest frame in a CPU sample.
    private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let key = timeZone.identifier + "|" + format
        formattersLock.lock(); defer { formattersLock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter
    }
}

/// All entry points use this policy. Calls and observable state belong to the
/// main thread; provider callbacks are marshalled there before changing state.
/// Only scheduling metadata is persisted, never credentials or usage data.
final class RefreshCoordinator {
    typealias Completion = (Result<ProviderUsage, UsageError>) -> Void
    typealias Fetch = (@escaping Completion) -> Void

    struct Schedule: Codable, Equatable {
        var lastStarted: Date?
        var blockedUntil: Date?
        var backoffStep = 0

        func normalized(at date: Date) -> Schedule {
            var result = self
            result.backoffStep = min(4, max(0, backoffStep))
            if let lastStarted { result.lastStarted = min(lastStarted, date) }
            if let blockedUntil {
                result.blockedUntil = min(blockedUntil, date.addingTimeInterval(RefreshCoordinator.maximumPause))
            }
            return result
        }
    }

    private struct State {
        var schedule: Schedule
        var inFlight = false
        var usage: ProviderUsage?
        var error: String?
    }

    static let providerIDs = ["claude", "codex"]
    /// Safety bound for corrupt persisted dates and implausible server delays.
    /// Ordinary Retry-After values above the 30-minute fallback are preserved.
    static let maximumPause: TimeInterval = 24 * 60 * 60
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetchers: [String: Fetch]
    private let log: (String) -> Void
    private var states: [String: State] = [:]
    private var interval: TimeInterval = 120
    private var codexEnabled = false
    private var lastCompleted: Date?

    var onChange: (() -> Void)?
    var onSnapshotChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         cachedPayload: SharedStore.Payload? = nil,
         fetchers: [String: Fetch], log: @escaping (String) -> Void = { _ in }) {
        self.defaults = defaults
        self.now = now
        self.fetchers = fetchers
        self.log = log
        lastCompleted = cachedPayload?.snapshot.fetchedAt
        let date = now()
        for id in Self.providerIDs {
            let stored = defaults.data(forKey: Self.key(id))
                .flatMap { try? JSONDecoder().decode(Schedule.self, from: $0) } ?? Schedule()
            let schedule = stored.normalized(at: date)
            let usage = cachedPayload?.snapshot.providers.first { $0.id == id }
            let cachedError = cachedPayload?.errors[id]
                ?? (usage == nil ? nil : "Saved data; waiting for next refresh")
            states[id] = State(schedule: schedule, usage: usage,
                               error: schedule.backoffStep > 0 ? "Last request was rate limited" : cachedError)
            if schedule != stored {
                persist(id)
                log("\(id): normalized restored request dates")
            }
        }
    }

    private static func key(_ id: String) -> String { "refreshSchedule.v1.\(id)" }
    private var enabledIDs: [String] { codexEnabled ? Self.providerIDs : ["claude"] }

    var snapshot: CombinedSnapshot {
        CombinedSnapshot(providers: enabledIDs.compactMap { states[$0]?.usage },
                         fetchedAt: lastCompleted ?? now())
    }

    var errors: [String: String] {
        Dictionary(uniqueKeysWithValues: enabledIDs.compactMap { id in
            states[id]?.error.map { (id, $0) }
        })
    }

    var statuses: [String: RefreshStatus] {
        let date = now()
        return Dictionary(uniqueKeysWithValues: enabledIDs.compactMap { id in
            guard let state = states[id] else { return nil }
            if state.inFlight { return (id, .refreshing) }
            let eligible = nextEligible(id)
            if let blocked = state.schedule.blockedUntil, blocked > date {
                return (id, .paused(until: max(blocked, eligible ?? blocked)))
            }
            if let eligible, eligible > date { return (id, .scheduled(after: eligible)) }
            return nil
        })
    }

    var hasRequestsInFlight: Bool { states.values.contains { $0.inFlight } }
    func schedule(for id: String) -> Schedule? { states[id]?.schedule }

    /// Wake at an actual provider deadline, rather than rounding a five-minute
    /// Claude interval up to the next tick of a two-minute global timer.
    var nextRefreshAt: Date? {
        enabledIDs.filter { states[$0]?.inFlight == false && fetchers[$0] != nil }
            .map { max(nextEligible($0) ?? now(), now()) }.min()
    }

    static func effectiveInterval(for id: String, selected: TimeInterval) -> TimeInterval {
        let valid = selected.isFinite && selected > 0 ? selected : 120
        return max(valid, id == "claude" ? 300 : 5)
    }

    static func intervalSummary(selected: TimeInterval, showCodex: Bool) -> String {
        func label(_ id: String) -> String {
            let minutes = effectiveInterval(for: id, selected: selected) / 60
            return String(format: "%g min", minutes)
        }
        return "Claude: every \(label("claude"))"
            + (showCodex ? " · Codex: every \(label("codex"))" : "")
    }

    private func nextEligible(_ id: String) -> Date? {
        guard let schedule = states[id]?.schedule else { return nil }
        let fromInterval = schedule.lastStarted.map {
            $0.addingTimeInterval(Self.effectiveInterval(for: id, selected: interval))
        }
        return [fromInterval, schedule.blockedUntil].compactMap { $0 }.max()
    }

    func refresh(trigger: RefreshTrigger, interval: TimeInterval, showCodex: Bool) {
        precondition(Thread.isMainThread)
        self.interval = interval
        let visibilityChanged = codexEnabled != showCodex
        codexEnabled = showCodex
        if !showCodex {
            states["codex"]?.usage = nil
            states["codex"]?.error = nil
        } else if states["codex"]?.schedule.backoffStep ?? 0 > 0,
                  states["codex"]?.error == nil {
            states["codex"]?.error = "Last request was rate limited"
        }

        let date = now()
        // Also repair state after a clock change while this process is alive.
        // Persist the correction once; later refreshes must not move the deadline.
        for id in Self.providerIDs {
            guard let stored = states[id]?.schedule else { continue }
            let normalized = stored.normalized(at: date)
            if normalized != stored {
                states[id]?.schedule = normalized
                persist(id)
                log("\(id): normalized request dates after clock change")
            }
        }
        for id in enabledIDs {
            guard var state = states[id], !state.inFlight,
                  nextEligible(id).map({ $0 <= date }) ?? true,
                  let fetch = fetchers[id] else { continue }
            // Reserve and persist before invoking a fetcher: it may complete
            // synchronously (for example, when credentials are missing).
            state.inFlight = true
            state.schedule.lastStarted = date
            states[id] = state
            persist(id)
            log("\(id): request started (\(trigger.rawValue))")
            fetch { [weak self] result in
                if Thread.isMainThread {
                    self?.complete(id, result)
                } else {
                    DispatchQueue.main.async { self?.complete(id, result) }
                }
            }
        }
        onChange?() // A skipped manual request still explains why in the panel.
        if visibilityChanged { onSnapshotChange?() }
    }

    private func complete(_ id: String, _ result: Result<ProviderUsage, UsageError>) {
        precondition(Thread.isMainThread)
        guard var state = states[id], state.inFlight else { return }
        let date = now()
        state.schedule = state.schedule.normalized(at: date)
        state.inFlight = false
        switch result {
        case .success(var usage):
            usage.fetchedAt = date
            state.schedule.blockedUntil = nil
            state.schedule.backoffStep = 0
            state.usage = usage
            state.error = nil
            log("\(id): ok, hottest \(Int(usage.hottestPercent))%")
        case .failure(let error):
            state.error = error.localizedDescription
            if case .rateLimited(let retryAfter) = error {
                state.schedule.backoffStep = min(4, state.schedule.backoffStep + 1)
                let delays: [TimeInterval] = [300, 600, 1200, 1800]
                let serverDate = retryAfter.flatMap { $0 > date ? $0 : nil }
                let requested = serverDate ?? date.addingTimeInterval(delays[state.schedule.backoffStep - 1])
                state.schedule.blockedUntil = min(requested, date.addingTimeInterval(Self.maximumPause))
                if state.schedule.blockedUntil != requested {
                    log("\(id): Retry-After exceeds safety horizon; capped at 24 hours")
                }
                let source = serverDate == nil ? "fallback step \(state.schedule.backoffStep)" : "Retry-After"
                log("\(id): rate limited; \(source); blocked until \(state.schedule.blockedUntil!)")
            } else {
                log("\(id): failed - \(error.localizedDescription)")
            }
        }
        // A response to a request started before hiding Codex updates its
        // persisted policy, but must not bring the hidden card back.
        if id == "codex" && !codexEnabled {
            state.usage = nil
            state.error = nil
        }
        states[id] = state
        persist(id)
        if case .failure(.rateLimited) = result, let eligible = nextEligible(id) {
            log("\(id): next request allowed after \(eligible)")
        }
        lastCompleted = date
        onChange?()
        onSnapshotChange?()
    }

    private func persist(_ id: String) {
        if let schedule = states[id]?.schedule,
           let data = try? JSONEncoder().encode(schedule) {
            defaults.set(data, forKey: Self.key(id))
        }
    }
}
