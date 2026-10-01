import Cocoa
import ServiceManagement

// Remove this bundle's login item. Used when retiring an old bundle identifier.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    print("login item status: \(SMAppService.mainApp.status.rawValue) (0 = not registered)")
    exit(0)
}

// Login-item check: register, read status, restore.
if CommandLine.arguments.contains("--test-login-item") {
    let was = SMAppService.mainApp.status
    do {
        try SMAppService.mainApp.register()
        print("register(): ok, status \(SMAppService.mainApp.status.rawValue) (1 = enabled)")
        if was != .enabled {
            try? SMAppService.mainApp.unregister()
            print("restored previous state: \(SMAppService.mainApp.status.rawValue)")
        }
    } catch {
        print("register(): FAILED - \(error.localizedDescription)")
    }
    exit(0)
}

// Diagnostic mode uses the same persisted gates as the menu bar app.
if CommandLine.arguments.contains("--diagnose") {
    // The App Group is easy to break silently: a wrong team id yields a
    // valid-looking build whose widget never receives anything.
    print("App Group: \(SharedStore.appGroup)")
    let container = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroup)
    // A directory is handed out even for a group this build has no entitlement
    // for, so its mere existence proves nothing. On macOS the identifier must
    // carry the team prefix, or the widget looks in a different container.
    let hasTeamPrefix = SharedStore.appGroup.contains(".group.")
    switch (container, hasTeamPrefix) {
    case (.some, true):
        print("  container: available - the widget will receive updates")
    case (.some, false):
        print("  container: present but the group has NO team prefix")
        print("  (normal for ./build.sh, which builds the app alone; the widget needs the Xcode build)")
    case (.none, _):
        print("  container: UNAVAILABLE - the widget would show no data")
        print("  (check DEVELOPMENT_TEAM in Team.xcconfig)")
    }

    let coordinator = RefreshCoordinator(
        fetchers: ["claude": ClaudeProvider.fetch, "codex": CodexProvider.fetch], log: { print($0) })
    let selected = UserDefaults.standard.double(forKey: "refreshIntervalSeconds")
    let showCodex = CodexProvider.isInstalled
        && (UserDefaults.standard.object(forKey: "showCodex") as? Bool ?? true)
    coordinator.refresh(trigger: .diagnostic, interval: selected, showCodex: showCodex)
    let deadline = Date().addingTimeInterval(65)
    while coordinator.hasRequestsInFlight && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    for usage in coordinator.snapshot.providers {
        print("\(usage.title): ok, plan \(usage.plan)")
        for row in usage.rows {
            let reset = row.resetsAt.map { " (resets \($0))" } ?? ""
            print("  \(row.title): \(row.percent)%\(reset)")
        }
        if let credits = usage.credits { print("  \(credits)") }
    }
    for (id, error) in coordinator.errors { print("\(id): \(error)") }
    for (id, status) in coordinator.statuses { print("\(id): \(status.text(now: Date()))") }
    exit(0)
}

let application = NSApplication.shared
let controller = StatusController()
application.delegate = controller
application.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
application.run()
