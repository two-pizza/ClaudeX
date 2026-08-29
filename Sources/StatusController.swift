import Cocoa
import ServiceManagement

final class StatusController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = UsageMenuView()
    private var timer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    private var snapshot: UsageSnapshot?
    private var lastError: Error?
    private var lastFetchStarted: Date?

    private enum Defaults {
        static let interval = "refreshIntervalSeconds"
        static let compact  = "compactStatusBar"
    }

    private var refreshInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Defaults.interval)
        return stored > 0 ? stored : 120
    }
    private var isCompact: Bool { UserDefaults.standard.bool(forKey: Defaults.compact) }

    // MARK: Жизненный цикл

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        // Кольцо рисуется под текущую тему, поэтому перерисовываем при её смене.
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

    // MARK: Данные

    @objc private func refresh() {
        // Меню умеет дёргать обновление при каждом открытии — не частим.
        if let started = lastFetchStarted, Date().timeIntervalSince(started) < 5 { return }
        lastFetchStarted = Date()

        UsageAPI.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.lastError = nil
                    Log.write("данные получены: сессия \(snapshot.session?.percent ?? -1)%, окон \(snapshot.weekly.count)")
                case .failure(let error):
                    self.lastError = error
                    Log.write("запрос не удался: \(error.localizedDescription) [\(error)]")
                }
                self.updateStatusButton()
                self.updatePanel()
            }
        }
    }

    // MARK: Строка меню

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        guard let snapshot else {
            button.image = Self.ringImage(percent: 0, color: .tertiaryLabelColor)
            button.title = lastError == nil ? "" : " —"
            button.toolTip = lastError?.localizedDescription
            return
        }

        let headline = snapshot.headlinePercent
        button.image = Self.ringImage(percent: headline, color: UsageMenuView.color(for: headline))

        if isCompact {
            button.title = ""
        } else {
            let parts = [snapshot.session?.percent, snapshot.weekly.first?.percent]
                .compactMap { $0 }
                .map { String(format: "%.0f%%", $0) }
            button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        }

        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.toolTip = lastError.map { "Последняя попытка не удалась: \($0.localizedDescription)" }
    }

    /// Кольцевой индикатор: серый ободок плюс дуга по часовой стрелке от 12 часов.
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

    // MARK: Меню

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Обновить", action: #selector(refreshFromMenu),
                                     keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let intervalItem = NSMenuItem(title: "Обновлять", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for (title, seconds) in [("каждую минуту", 60.0), ("каждые 2 минуты", 120.0),
                                 ("каждые 5 минут", 300.0), ("каждые 15 минут", 900.0)] {
            let item = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = refreshInterval == seconds ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let compactItem = NSMenuItem(title: "Компактно (только кольцо)",
                                     action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = isCompact ? .on : .off
        menu.addItem(compactItem)

        let loginItem = NSMenuItem(title: "Запускать при входе",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let siteItem = NSMenuItem(title: "Открыть настройки на claude.ai",
                                  action: #selector(openSettings), keyEquivalent: "")
        siteItem.target = self
        menu.addItem(siteItem)

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePanel()
        refresh()
        // Галочки могли разъехаться, если настройки менялись из другого места.
        for item in menu.items {
            switch item.title {
            case "Компактно (только кольцо)":
                item.state = isCompact ? .on : .off
            case "Запускать при входе":
                item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            case "Обновлять":
                item.submenu?.items.forEach {
                    $0.state = ($0.representedObject as? Double) == refreshInterval ? .on : .off
                }
            default: break
            }
        }
    }

    private func updatePanel() {
        if let snapshot, lastError == nil {
            panel.render(snapshot: snapshot)
        } else if let lastError {
            panel.render(error: lastError, lastSnapshot: snapshot)
        }
    }

    // MARK: Действия

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

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }
}
