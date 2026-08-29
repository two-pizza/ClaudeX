import Foundation

// MARK: - Ответ /api/oauth/usage

private struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Named: Decodable { let displayName: String? }
            let model: Named?
            let surface: Named?
        }
        let kind: String
        let group: String
        let percent: Double
        let severity: String?
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

// MARK: - Модель для отрисовки

struct UsageRow {
    let title: String
    let percent: Double
    let resetsAt: Date?
    /// Сессионное окно показываем относительным временем («через 4 ч 55 мин»),
    /// недельные — днём и часом («Пт 19:00»).
    let isSession: Bool
    let isActive: Bool
}

struct UsageSnapshot {
    let plan: String
    let session: UsageRow?
    let weekly: [UsageRow]
    let credits: String?
    let fetchedAt: Date

    /// Число, которое уходит в строку меню: самое «горячее» из окон.
    var headlinePercent: Double {
        ([session].compactMap { $0 } + weekly).map(\.percent).max() ?? 0
    }
}

// MARK: - Сеть

enum UsageError: LocalizedError {
    case unauthorized
    case http(Int)
    case transport(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unauthorized:      return "Токен отклонён — запусти claude и войди заново"
        case .http(let code):    return "Сервер ответил \(code)"
        case .transport(let m):  return m
        case .malformed:         return "Не разобрать ответ сервера"
        }
    }
}

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
    }

    /// Транспортные сбои повторяем: первый запрос после пересборки часто режет сетевой
    /// фильтр, а после пробуждения из сна интерфейс поднимается не мгновенно.
    /// Отказы авторизации и коды ответа не повторяем — они не рассосутся сами.
    static func fetch(attempt: Int = 1,
                      completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        let credentials: ClaudeCredentials
        do { credentials = try Keychain.readCredentials() }
        catch { completion(.failure(error)); return }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                let delays: [TimeInterval] = [3, 10]
                if attempt <= delays.count {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delays[attempt - 1]) {
                        fetch(attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(.failure(UsageError.transport(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(http.statusCode == 401 ? UsageError.unauthorized
                                                           : UsageError.http(http.statusCode)))
                return
            }
            guard let data,
                  let decoded = try? decoder.decode(UsageResponse.self, from: data) else {
                completion(.failure(UsageError.malformed))
                return
            }
            completion(.success(snapshot(from: decoded, plan: credentials.planLabel)))
        }.resume()
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: Сборка снимка

    private static func snapshot(from response: UsageResponse, plan: String) -> UsageSnapshot {
        var session: UsageRow?
        var weekly: [UsageRow] = []

        // limits[] — ровно тот список, что рисует сам Claude Code, поэтому он первичен.
        for limit in response.limits ?? [] {
            let row = UsageRow(title: title(for: limit),
                               percent: limit.percent,
                               resetsAt: parseDate(limit.resetsAt),
                               isSession: limit.group == "session",
                               isActive: limit.isActive ?? false)
            if limit.group == "session" { session = row } else { weekly.append(row) }
        }

        // Запасной путь: сервер вернул окна, но не собрал limits[].
        if session == nil, let window = response.fiveHour, let percent = window.utilization {
            session = UsageRow(title: "Current session", percent: percent,
                               resetsAt: parseDate(window.resetsAt), isSession: true, isActive: true)
        }
        if weekly.isEmpty, let window = response.sevenDay, let percent = window.utilization {
            weekly.append(UsageRow(title: "All models", percent: percent,
                                   resetsAt: parseDate(window.resetsAt),
                                   isSession: false, isActive: true))
        }

        return UsageSnapshot(plan: plan,
                             session: session,
                             weekly: weekly,
                             credits: creditsLine(response.extraUsage),
                             fetchedAt: Date())
    }

    private static func title(for limit: UsageResponse.Limit) -> String {
        if let name = limit.scope?.model?.displayName ?? limit.scope?.surface?.displayName {
            return name
        }
        switch limit.kind {
        case "session":     return "Current session"
        case "weekly_all":  return "All models"
        default:            return limit.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func creditsLine(_ extra: UsageResponse.ExtraUsage?) -> String? {
        guard let extra, extra.isEnabled == true else { return nil }
        guard let used = extra.usedCredits else { return "Usage credits включены" }
        let symbol = (extra.currency ?? "USD") == "USD" ? "$" : ""
        if let limit = extra.monthlyLimit {
            return String(format: "Usage credits: %@%.2f из %@%.2f", symbol, used, symbol, limit)
        }
        return String(format: "Usage credits: %@%.2f", symbol, used)
    }
}
