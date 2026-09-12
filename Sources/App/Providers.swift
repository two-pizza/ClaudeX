import Foundation

/// Shared plumbing: request with transport-level retry.
/// The first request after a rebuild is often cut by network filters, and the
/// interface is not up instantly after wake - so transport failures retry.
/// Auth failures and HTTP status codes do not: they won't fix themselves.
enum HTTPClient {
    static func get(_ request: URLRequest, attempt: Int = 1,
                    completion: @escaping (Result<Data, UsageError>) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                let delays: [TimeInterval] = [3, 10]
                if attempt <= delays.count {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delays[attempt - 1]) {
                        get(request, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                switch http.statusCode {
                case 401, 403: completion(.failure(.unauthorized("re-login and retry")))
                case 429:      completion(.failure(.rateLimited))
                default:       completion(.failure(.http(http.statusCode)))
                }
                return
            }
            guard let data else { completion(.failure(.malformedResponse)); return }
            completion(.success(data))
        }.resume()
    }
}

/// `--diagnose --raw`: print response bodies so a parsing gap can be seen.
/// Bodies carry usage numbers only - tokens travel in request headers.
enum RawCapture {
    static var enabled = false
    static func dump(_ name: String, _ data: Data) {
        guard enabled else { return }
        print("--- \(name) raw response ---")
        print(String(decoding: data, as: UTF8.self))
    }
}

enum DateParsing {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func iso(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
    }
}

// MARK: - Claude

/// GET https://api.anthropic.com/api/oauth/usage with the Claude Code OAuth token.
/// The token is read from the Keychain and NEVER refreshed here: refreshing
/// rotates the refresh token and would steal Claude Code's own authorization.
enum ClaudeProvider {
    private struct Response: Decodable {
        struct Window: Decodable { let utilization: Double?; let resetsAt: String? }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Named: Decodable { let displayName: String? }
                let model: Named?
                let surface: Named?
            }
            let kind: String
            let group: String
            let percent: Double
            let resetsAt: String?
            let scope: Scope?
            let isActive: Bool?
        }
        struct ExtraUsage: Decodable {
            let isEnabled: Bool?
            let utilization: Double?
            let usedCredits: Double?
            let monthlyLimit: Double?
            let currency: String?
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?
        let extraUsage: ExtraUsage?
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func fetch(completion: @escaping (Result<ProviderUsage, UsageError>) -> Void) {
        let credentials: ClaudeCredentials
        do { credentials = try Keychain.readCredentials() }
        catch let error as UsageError { completion(.failure(error)); return }
        catch { completion(.failure(.malformedAuth)); return }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                                 timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        HTTPClient.get(request) { result in
            completion(result.flatMap { data in
                RawCapture.dump("Claude", data)
                guard let decoded = try? decoder.decode(Response.self, from: data) else {
                    return .failure(.malformedResponse)
                }
                return .success(usage(from: decoded, plan: credentials.planLabel))
            })
        }
    }

    private static func usage(from response: Response, plan: String) -> ProviderUsage {
        var rows: [UsageRow] = []

        // limits[] is exactly the list Claude Code itself renders, so it is primary.
        for limit in response.limits ?? [] {
            rows.append(UsageRow(title: title(for: limit),
                                 percent: limit.percent,
                                 resetsAt: DateParsing.iso(limit.resetsAt),
                                 isSession: limit.group == "session",
                                 isActive: limit.isActive ?? false))
        }

        // Fallback: the server returned windows but did not assemble limits[].
        if rows.isEmpty {
            if let window = response.fiveHour, let percent = window.utilization {
                rows.append(UsageRow(title: "Current session", percent: percent,
                                     resetsAt: DateParsing.iso(window.resetsAt),
                                     isSession: true, isActive: true))
            }
            if let window = response.sevenDay, let percent = window.utilization {
                rows.append(UsageRow(title: "All models", percent: percent,
                                     resetsAt: DateParsing.iso(window.resetsAt),
                                     isSession: false, isActive: true))
            }
        }

        // Sessions first, then weekly - same order as the /usage screen.
        rows.sort { $0.isSession && !$1.isSession }

        return ProviderUsage(id: "claude", title: "Claude", plan: plan,
                             rows: rows, credits: creditsLine(response.extraUsage))
    }

    private static func title(for limit: Response.Limit) -> String {
        if let name = limit.scope?.model?.displayName ?? limit.scope?.surface?.displayName {
            return name
        }
        switch limit.kind {
        case "session":     return "Current session"
        case "weekly_all":  return "All models"
        default:            return limit.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func creditsLine(_ extra: Response.ExtraUsage?) -> String? {
        guard let extra, extra.isEnabled == true else { return nil }
        guard let used = extra.usedCredits else { return "Usage credits enabled" }
        let symbol = (extra.currency ?? "USD") == "USD" ? "$" : ""
        if let limit = extra.monthlyLimit {
            return String(format: "Usage credits: %@%.2f of %@%.2f", symbol, used, symbol, limit)
        }
        return String(format: "Usage credits: %@%.2f", symbol, used)
    }
}

// MARK: - Codex

/// GET https://chatgpt.com/backend-api/wham/usage with the Codex CLI ChatGPT token.
/// Same policy as Claude: the token in ~/.codex/auth.json is read-only for us -
/// Codex CLI refreshes it itself whenever it runs.
enum CodexProvider {
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: authPath.path)
    }

    private static let authPath = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")

    private struct Auth: Decodable {
        struct Tokens: Decodable { let accessToken: String?; let accountId: String? }
        let tokens: Tokens?
    }

    private struct Response: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Double?
            let resetAt: Double?
        }
        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?
        }
        struct Credits: Decodable {
            let hasCredits: Bool?
            let unlimited: Bool?
            let balance: String?
        }
        let planType: String?
        let rateLimit: RateLimit?
        let credits: Credits?
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func fetch(completion: @escaping (Result<ProviderUsage, UsageError>) -> Void) {
        guard let data = try? Data(contentsOf: authPath),
              let auth = try? decoder.decode(Auth.self, from: data) else {
            completion(.failure(.notLoggedIn("Codex")))
            return
        }
        guard let token = auth.tokens?.accessToken, !token.isEmpty,
              let account = auth.tokens?.accountId else {
            completion(.failure(.notLoggedIn("Codex")))
            return
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                                 timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        HTTPClient.get(request) { result in
            completion(result.flatMap { data in
                RawCapture.dump("Codex", data)
                guard let decoded = try? decoder.decode(Response.self, from: data) else {
                    return .failure(.malformedResponse)
                }
                return .success(usage(from: decoded))
            })
        }
    }

    private static func usage(from response: Response) -> ProviderUsage {
        var rows: [UsageRow] = []

        if let window = response.rateLimit?.primaryWindow, let percent = window.usedPercent {
            rows.append(row(window: window, percent: percent))
        }
        if let window = response.rateLimit?.secondaryWindow, let percent = window.usedPercent {
            rows.append(row(window: window, percent: percent))
        }

        let plan = (response.planType ?? "").isEmpty ? "ChatGPT" : response.planType!.capitalized

        // Credits are the buffer past the plan limits; show the balance when there is one.
        var credits: String? = nil
        if let c = response.credits, c.hasCredits == true {
            if c.unlimited == true {
                credits = "Credits: unlimited"
            } else if let balance = c.balance.flatMap(Double.init) {
                credits = String(format: "Credits: %.2f left", balance)
            }
        }
        return ProviderUsage(id: "codex", title: "Codex", plan: plan, rows: rows, credits: credits)
    }

    private static func row(window: Response.Window, percent: Double) -> UsageRow {
        // Codex does not name its windows; label them by duration.
        let seconds = window.limitWindowSeconds ?? 0
        let isSession = seconds > 0 && seconds <= 6 * 3600
        let title: String
        if isSession {
            title = "Current session"
        } else if seconds >= 6 * 86400 {
            title = "Weekly"
        } else {
            title = "\(Int(seconds / 3600))-hour window"
        }
        return UsageRow(title: title, percent: percent,
                        resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) },
                        isSession: isSession, isActive: true)
    }
}
