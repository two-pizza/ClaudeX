import Cocoa
import ServiceManagement

// Диагностический режим: один запрос, печать результата, выход. Токен не выводится.
// Проверка автозапуска: включить, прочитать статус, вернуть как было.
if CommandLine.arguments.contains("--test-login-item") {
    import_check: do {
        let was = SMAppService.mainApp.status
        do {
            try SMAppService.mainApp.register()
            print("register(): ок, статус \(SMAppService.mainApp.status.rawValue) (1 = enabled)")
        } catch {
            print("register(): ОШИБКА — \(error.localizedDescription)")
            break import_check
        }
        if was != .enabled {
            try? SMAppService.mainApp.unregister()
            print("возвращено исходное состояние: \(SMAppService.mainApp.status.rawValue)")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    let done = DispatchSemaphore(value: 0)

    do {
        let credentials = try Keychain.readCredentials()
        print("Keychain: ок, план «\(credentials.planLabel)», токен длиной \(credentials.accessToken.count)")
    } catch {
        print("Keychain: ОШИБКА — \(error.localizedDescription)")
    }

    UsageAPI.fetch { result in
        switch result {
        case .success(let snapshot):
            print("API: ок, план «\(snapshot.plan)»")
            if let session = snapshot.session {
                print("  сессия: \(session.percent)%, сброс \(session.resetsAt.map(String.init(describing:)) ?? "—")")
            }
            for row in snapshot.weekly {
                print("  \(row.title): \(row.percent)%")
            }
            if let credits = snapshot.credits { print("  \(credits)") }
        case .failure(let error):
            print("API: ОШИБКА — \(error.localizedDescription)  [\(error)]")
        }
        done.signal()
    }

    _ = done.wait(timeout: .now() + 30)
    exit(0)
}

let application = NSApplication.shared
let controller = StatusController()
application.delegate = controller
application.setActivationPolicy(.accessory)   // только строка меню, без иконки в Dock
application.run()
