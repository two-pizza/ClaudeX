import Foundation

/// Claude Code credentials stored in the Keychain under "Claude Code-credentials".
struct ClaudeCredentials {
    let accessToken: String
    let subscriptionType: String?
    let rateLimitTier: String?

    /// "Max", "Ultra", "Pro", etc. - for the panel header.
    var planLabel: String {
        let tier = rateLimitTier?.lowercased()
        let base: String
        switch subscriptionType?.lowercased() {
        case "ultra": return "Ultra"
        case "max":
            // Max 20x was renamed Ultra and Max 5x became plain Max; the
            // Keychain still says "max" for both, only the tier tells them apart.
            // Only the tiers seen so far are mapped - an unknown one keeps the
            // generic "Max (Nx)" label below.
            switch tier {
            case "default_claude_max_20x", "max_20x": return "Ultra"
            case "default_claude_max_5x", "max_5x": return "Max"
            default: base = "Max"
            }
        case "pro": base = "Pro"
        case "team": base = "Team"
        case "enterprise": base = "Enterprise"
        case .some(let other) where !other.isEmpty: base = other.capitalized
        default: return "Claude"
        }
        // Any other tier: show its multiplier if it has one.
        if let tier,
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
