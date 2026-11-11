import Cocoa
import ServiceManagement
#if canImport(WidgetKit)
import WidgetKit
#endif

final class StatusController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = UsageMenuView()
    private var timer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    /// What the status button shows now. Setting any button property makes
    /// AppKit redraw the status item's replicas, which reports an
    /// effectiveAppearance change again; applying only real changes breaks
    /// that loop (1.2.3 spun a whole core in it).
    private var shownButton: ButtonState?
    private var clockChangeObserver: NSObjectProtocol?

    private let coordinator = RefreshCoordinator(
        cachedPayload: SharedStore.read(),
        fetchers: ["claude": ClaudeProvider.fetch, "codex": CodexProvider.fetch], log: Log.write)
    private var intervalSummaryItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var updateTimer: Timer?
    private lazy var updateChecker: UpdateChecker = {
        let version = currentVersion
        let checker = UpdateChecker { completion in UpdateCheck.fetch(current: version, completion: completion) }
        checker.onResult = { [weak self] in self?.showUpdateResult($0) }
        checker.present = { [weak self] outcome, done in
            self?.presentUpdateResult(outcome)
            done()
        }
        return checker
    }()

    private enum Defaults {
        static let interval = "refreshIntervalSeconds"
        static let compact  = "compactStatusBar"
        static let codex    = "showCodex"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    private var refreshInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Defaults.interval)
        return stored.isFinite && stored > 0 ? stored : 120
    }
    private var isCompact: Bool { UserDefaults.standard.bool(forKey: Defaults.compact) }
    private var showCodex: Bool {
        guard CodexProvider.isInstalled else { return false }
        return UserDefaults.standard.object(forKey: Defaults.codex) as? Bool ?? true
    }

    private var snapshot: CombinedSnapshot { coordinator.snapshot }
    private var errors: [String: String] { coordinator.errors }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.onChange = { [weak self] in
            self?.updateStatusButton()
            self?.updatePanel()
            self?.restartTimer()
        }
        coordinator.onSnapshotChange = { [weak self] in self?.publishToWidget() }
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        // The ring is drawn for the current theme - redraw when it changes.
        // The observer fires on every replica redraw too, so compare the
        // resolved light/dark theme before doing anything.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateStatusButton() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAfterWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        clockChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.refresh(.clockChange)
            }

        updateStatusButton()
        refresh(.launch)
        publishToWidget()
        restartTimer()

        // Quiet daily check; the hourly tick only decides whether a day has passed.
        checkForUpdatesIfDue()
        let updateTimer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdatesIfDue()
        }
        updateTimer.tolerance = 300
        RunLoop.main.add(updateTimer, forMode: .common)
        self.updateTimer = updateTimer
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard let next = coordinator.nextRefreshAt else { return }
        let delay = max(0.1, next.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.refresh(.timer)
        }
        timer.tolerance = min(5, delay * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Data

    private func refresh(_ trigger: RefreshTrigger) {
        coordinator.refresh(trigger: trigger, interval: refreshInterval, showCodex: showCodex)
    }

    @objc private func refreshAfterWake() { refresh(.wake) }

    /// Hands the fresh numbers to the widget. No-op in builds without the
    /// App Group entitlement, so the ad-hoc build keeps working unchanged.
    private func publishToWidget() {
        guard SharedStore.write(snapshot: snapshot, errors: errors) else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Status bar

    private struct ButtonState: Equatable {
        var percent: Double?   // nil: no data yet, gray empty ring
        var title: String
        var toolTip: String
        var appearance: NSAppearance.Name?
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        let snapshot = self.snapshot
        let appearance = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let details = statusDetails
        let state: ButtonState
        if snapshot.providers.isEmpty {
            state = ButtonState(percent: nil, title: errors.isEmpty ? "" : " —",
                                toolTip: details, appearance: appearance)
        } else {
            // One number per provider: its hottest window.
            let parts = snapshot.providers.map { String(format: "%.0f%%", $0.hottestPercent) }
            let tip = snapshot.providers
                .map { "\($0.title): \(Int($0.hottestPercent))%" }
                .joined(separator: "\n")
                + (details.isEmpty ? "" : "\n" + details)
            state = ButtonState(percent: snapshot.headlinePercent,
                                title: isCompact ? "" : " " + parts.joined(separator: " · "),
                                toolTip: tip, appearance: appearance)
        }

        let previous = shownButton
        guard state != previous else { return }
        shownButton = state

        if state.percent != previous?.percent || state.appearance != previous?.appearance || previous == nil {
            if let percent = state.percent {
                button.image = Self.ringImage(percent: percent, color: UsageMenuView.color(for: percent))
            } else {
                button.image = Self.ringImage(percent: 0, color: .tertiaryLabelColor)
            }
        }
        if previous == nil {
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        if state.title != previous?.title { button.title = state.title }
        if state.toolTip != previous?.toolTip { button.toolTip = state.toolTip }
    }

    private var statusDetails: String {
        let statuses = coordinator.statuses
        return RefreshCoordinator.providerIDs.compactMap { id in
            let message = statuses[id]?.text(now: Date()) ?? errors[id]
            return message.map { "\(id.capitalized): \($0)" }
        }.joined(separator: "\n")
    }

    /// Ring indicator: gray track plus a clockwise arc from 12 o'clock.
    private static func ringImage(percent: Double, color: NSColor) -> NSImage {
        let side: CGFloat = 15
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth: CGFloat = 2.4
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (side - lineWidth) / 2 - 0.5

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.quaternaryLabelColor.setStroke()
            track.stroke()

            let fraction = max(0, min(percent, 100)) / 100
            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Menu

    private enum ItemTitle {
        static let compact = "Compact (ring only)"
        static let codex   = "Show Codex usage"
        static let login   = "Launch at login"
        static let every   = "Refresh every"
        static let update  = "Check for Updates…"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshFromMenu),
                                     keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let intervalItem = NSMenuItem(title: ItemTitle.every, action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for (title, seconds) in [("1 minute", 60.0), ("2 minutes", 120.0),
                                 ("5 minutes", 300.0), ("15 minutes", 900.0)] {
            let item = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = refreshInterval == seconds ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalMenu.addItem(.separator())
        let summary = NSMenuItem(title: RefreshCoordinator.intervalSummary(
            selected: refreshInterval, showCodex: showCodex), action: nil, keyEquivalent: "")
        intervalMenu.addItem(summary)
        intervalSummaryItem = summary
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let compactItem = NSMenuItem(title: ItemTitle.compact,
                                     action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.target = self
        menu.addItem(compactItem)

        if CodexProvider.isInstalled {
            let codexItem = NSMenuItem(title: ItemTitle.codex,
                                       action: #selector(toggleCodex), keyEquivalent: "")
            codexItem.target = self
            menu.addItem(codexItem)
        }

        let loginItem = NSMenuItem(title: ItemTitle.login,
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: ItemTitle.update,
                                    action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        self.updateItem = updateItem

        let siteItem = NSMenuItem(title: "Open claude.ai usage settings",
                                  action: #selector(openSettings), keyEquivalent: "")
        siteItem.target = self
        menu.addItem(siteItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePanel()
        refresh(.menu)
        intervalSummaryItem?.title = RefreshCoordinator.intervalSummary(
            selected: refreshInterval, showCodex: showCodex)
        for item in menu.items {
            switch item.title {
            case ItemTitle.compact: item.state = isCompact ? .on : .off
            case ItemTitle.codex:   item.state = showCodex ? .on : .off
            case ItemTitle.login:   item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            case ItemTitle.every:
                item.submenu?.items.forEach {
                    $0.state = ($0.representedObject as? Double) == refreshInterval ? .on : .off
                }
            default: break
            }
        }
    }

    private func updatePanel() {
        panel.render(snapshot: snapshot, errors: errors, statuses: coordinator.statuses)
    }

    // MARK: Actions

    @objc private func refreshFromMenu() {
        refresh(.manual)
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(seconds, forKey: Defaults.interval)
        refresh(.settings)
    }

    @objc private func toggleCompact() {
        UserDefaults.standard.set(!isCompact, forKey: Defaults.compact)
        updateStatusButton()
    }

    @objc private func toggleCodex() {
        UserDefaults.standard.set(!showCodex, forKey: Defaults.codex)
        refresh(.visibility)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    // MARK: Updates

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The Xcode build embeds the widget; the release zip does not.
    private var includesWidget: Bool {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(
            atPath: plugIns.appendingPathComponent("ClaudeXWidget.appex").path)
    }

    private func checkForUpdatesIfDue() {
        let last = UserDefaults.standard.object(forKey: Defaults.lastUpdateCheck) as? Date
        // A date in the future (clock set back) counts as due.
        if let last, last <= Date(), Date().timeIntervalSince(last) < UpdateCheck.interval { return }
        UserDefaults.standard.set(Date(), forKey: Defaults.lastUpdateCheck)
        updateChecker.check(manual: false)
    }

    @objc private func checkForUpdatesFromMenu() {
        UserDefaults.standard.set(Date(), forKey: Defaults.lastUpdateCheck)
        updateChecker.check(manual: true)
    }

    /// The menu item names a newer release once a check has found one;
    /// a failed check leaves it as it was.
    private func showUpdateResult(_ outcome: UpdateCheck.Outcome) {
        switch outcome {
        case .available(let release): updateItem?.title = "Update Available: \(release.version)…"
        case .upToDate: updateItem?.title = ItemTitle.update
        case .failed(let reason): Log.write("update check: \(reason)")
        }
    }

    private func presentUpdateResult(_ outcome: UpdateCheck.Outcome) {
        let alert = NSAlert()
        var openOnConfirm: URL?
        switch outcome {
        case .available(let release):
            alert.messageText = "ClaudeX \(release.version) is available"
            if includesWidget {
                alert.informativeText = "You have \(currentVersion). This copy includes the "
                    + "desktop widget, and the download is the menu bar app only - rebuild from "
                    + "source to keep the widget."
                alert.addButton(withTitle: "Open Release Page")
                openOnConfirm = release.pageURL
            } else {
                alert.informativeText = "You have \(currentVersion). Download the zip, "
                    + "unzip it and replace ClaudeX in Applications."
                alert.addButton(withTitle: "Download")
                openOnConfirm = release.downloadURL ?? release.pageURL
            }
            alert.addButton(withTitle: "Later")
        case .upToDate(let current):
            alert.messageText = "You're up to date"
            alert.informativeText = "ClaudeX \(current) is the latest version."
        case .failed(let reason):
            alert.messageText = "Could not check for updates"
            alert.informativeText = reason
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url = openOnConfirm {
            NSWorkspace.shared.open(url)
        }
    }
}
