import Foundation

/// Claude Code credentials stored in the Keychain under "Claude Code-credentials".
struct ClaudeCredentials {
    let accessToken: String
    let subscriptionType: String?
    let rateLimitTier: String?

    /// "Max (5x)", "Pro", etc. - for the panel header.
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
        // rateLimitTier on Max plans looks like "max_5x" / "max_20x".
        if let tier = rateLimitTier?.lowercased(),
           let range = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            return "\(base) (\(tier[range]))"
        }
        return base
    }
}

enum Keychain {
    /// Reads via /usr/bin/security rather than SecItemCopyMatching, deliberately:
    /// the item's ACL binds to the calling binary, and our ad-hoc signature changes
    /// on every rebuild - macOS would re-prompt after each build. /usr/bin/security
    /// has a stable signature, so "Always Allow" is granted once.
    static func readCredentials() throws -> ClaudeCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch { throw UsageError.notLoggedIn("Claude Code") }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw process.terminationStatus == 128 ? UsageError.keychainDenied
                                                   : UsageError.notLoggedIn("Claude Code")
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
            throw UsageError.malformedAuth
        }

        return ClaudeCredentials(accessToken: oauth.accessToken,
                                 subscriptionType: oauth.subscriptionType,
                                 rateLimitTier: oauth.rateLimitTier)
    }
}
