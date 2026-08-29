import Cocoa
import ServiceManagement

final class StatusController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = UsageMenuView()
    private var timer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    /// Last good result per provider - one provider failing must not blank the other.
    private var providers: [String: ProviderUsage] = [:]
    private var errors: [String: String] = [:]
    private var fetchedAt: Date?
    private var lastFetchStarted: Date?

    private enum Defaults {
        static let interval = "refreshIntervalSeconds"
        static let compact  = "compactStatusBar"
        static let codex    = "showCodex"
    }

    private var refreshInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Defaults.interval)
        return stored > 0 ? stored : 120
    }
    private var isCompact: Bool { UserDefaults.standard.bool(forKey: Defaults.compact) }
    private var showCodex: Bool {
        guard CodexProvider.isInstalled else { return false }
        return UserDefaults.standard.object(forKey: Defaults.codex) as? Bool ?? true
    }

    private var snapshot: CombinedSnapshot? {
        guard let fetchedAt else { return nil }
        let order = ["claude", "codex"]
        let list = order.compactMap { providers[$0] }
        return CombinedSnapshot(providers: list, fetchedAt: fetchedAt)
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        // The ring is drawn for the current theme - redraw when it changes.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateStatusButton() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)

        updateStatusButton()
        refresh()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = refreshInterval * 0.2
        self.timer = timer
    }

    // MARK: Data

    @objc private func refresh() {
        // The menu triggers a refresh on every open - don't hammer the API.
        if let started = lastFetchStarted, Date().timeIntervalSince(started) < 5 { return }
        lastFetchStarted = Date()

        let group = DispatchGroup()
        var fresh: [String: Result<ProviderUsage, UsageError>] = [:]
        let lock = NSLock()

        func collect(_ id: String, _ result: Result<ProviderUsage, UsageError>) {
            lock.lock(); fresh[id] = result; lock.unlock()
            group.leave()
        }

        group.enter()
        ClaudeProvider.fetch { collect("claude", $0) }
        if showCodex {
            group.enter()
            CodexProvider.fetch { collect("codex", $0) }
        } else {
            providers["codex"] = nil
            errors["codex"] = nil
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for (id, result) in fresh {
                switch result {
                case .success(let usage):
                    self.providers[id] = usage
                    self.errors[id] = nil
                    Log.write("\(id): ok, hottest \(Int(usage.hottestPercent))%")
                case .failure(let error):
                    self.errors[id] = error.localizedDescription
                    Log.write("\(id): failed - \(error.localizedDescription)")
                }
            }
            self.fetchedAt = Date()
            self.updateStatusButton()
            self.updatePanel()
        }
    }

    // MARK: Status bar

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        guard let snapshot, !snapshot.providers.isEmpty else {
            button.image = Self.ringImage(percent: 0, color: .tertiaryLabelColor)
            button.title = errors.isEmpty ? "" : " —"
            button.toolTip = errors.values.joined(separator: "\n")
            return
        }

        let headline = snapshot.headlinePercent
        button.image = Self.ringImage(percent: headline, color: UsageMenuView.color(for: headline))

        if isCompact {
            button.title = ""
        } else {
            // One number per provider: its hottest window.
            let parts = snapshot.providers.map { String(format: "%.0f%%", $0.hottestPercent) }
            button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        }

        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.toolTip = snapshot.providers
            .map { "\($0.title): \(Int($0.hottestPercent))%" }
            .joined(separator: "\n")
            + (errors.isEmpty ? "" : "\n" + errors.values.joined(separator: "\n"))
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
        // Refresh on open only when the data is stale: the usage endpoints
        // rate-limit aggressively (429) if polled on every click.
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 60 { } else { refresh() }
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
        let current = snapshot ?? CombinedSnapshot(providers: [], fetchedAt: Date())
        panel.render(snapshot: current, errors: errors)
    }

    // MARK: Actions

    @objc private func refreshFromMenu() {
        lastFetchStarted = nil
        refresh()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(seconds, forKey: Defaults.interval)
        restartTimer()
    }

    @objc private func toggleCompact() {
        UserDefaults.standard.set(!isCompact, forKey: Defaults.compact)
        updateStatusButton()
    }

    @objc private func toggleCodex() {
        UserDefaults.standard.set(!showCodex, forKey: Defaults.codex)
        lastFetchStarted = nil
        refresh()
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
}
