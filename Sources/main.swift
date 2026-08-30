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

// Diagnostic mode: one fetch per provider, print the result, exit. Tokens are never printed.
if CommandLine.arguments.contains("--diagnose") {
    let done = DispatchSemaphore(value: 0)
    var pending = 1 + (CodexProvider.isInstalled ? 1 : 0)
    let lock = NSLock()
    func finish() {
        lock.lock(); pending -= 1; let left = pending; lock.unlock()
        if left == 0 { done.signal() }
    }

    func report(_ name: String, _ result: Result<ProviderUsage, UsageError>) {
        switch result {
        case .success(let usage):
            print("\(name): ok, plan \(usage.plan)")
            for row in usage.rows {
                let reset = row.resetsAt.map { " (resets \($0))" } ?? ""
                print("  \(row.title): \(row.percent)%\(reset)")
            }
            if let credits = usage.credits { print("  \(credits)") }
        case .failure(let error):
            print("\(name): FAILED - \(error.localizedDescription)")
        }
        finish()
    }

    ClaudeProvider.fetch { report("Claude", $0) }
    if CodexProvider.isInstalled { CodexProvider.fetch { report("Codex", $0) } }
    _ = done.wait(timeout: .now() + 40)
    exit(0)
}

let application = NSApplication.shared
let controller = StatusController()
application.delegate = controller
application.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
application.run()
