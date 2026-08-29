import Foundation

/// Учётные данные Claude Code, лежащие в Keychain под сервисом "Claude Code-credentials".
struct ClaudeCredentials {
    let accessToken: String
    let subscriptionType: String?
    let rateLimitTier: String?

    /// "Max (5x)", "Pro" и т.п. — для шапки меню.
    var planLabel: String {
        let base: String
        switch subscriptionType?.lowercased() {
        case "max": base = "Max"
        case "pro": base = "Pro"
        case "team": base = "Team"
        case "enterprise": base = "Enterprise"
        case .some(let other) where !other.isEmpty: base = other.capitalized
        default: return "Claude"
        }
        // rateLimitTier у Max выглядит как "max_5x" / "max_20x"
        if let tier = rateLimitTier?.lowercased(),
           let range = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            return "\(base) (\(tier[range]))"
        }
        return base
    }
}

enum KeychainError: LocalizedError {
    case notFound
    case denied
    case malformed

    var errorDescription: String? {
        switch self {
        case .notFound:  return "Claude Code не авторизован в Keychain"
        case .denied:    return "Нет доступа к Keychain — разреши доступ в диалоге"
        case .malformed: return "Не разобрать запись Keychain"
        }
    }
}

enum Keychain {
    /// Читаем через /usr/bin/security, а не через SecItemCopyMatching, намеренно:
    /// ACL элемента привязывается к запрашивающему бинарю, а ad-hoc подпись меняется
    /// при каждой пересборке — тогда macOS спрашивала бы доступ снова после каждой сборки.
    /// У /usr/bin/security подпись стабильна, поэтому «Всегда разрешать» даётся один раз.
    static func readCredentials() throws -> ClaudeCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch { throw KeychainError.notFound }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw process.terminationStatus == 128 ? KeychainError.denied : KeychainError.notFound
        }

        struct Envelope: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let subscriptionType: String?
                let rateLimitTier: String?
            }
            let claudeAiOauth: OAuth?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let oauth = envelope.claudeAiOauth,
              !oauth.accessToken.isEmpty else {
            throw KeychainError.malformed
        }

        return ClaudeCredentials(accessToken: oauth.accessToken,
                                 subscriptionType: oauth.subscriptionType,
                                 rateLimitTier: oauth.rateLimitTier)
    }
}
