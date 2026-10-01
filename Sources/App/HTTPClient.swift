import Foundation

enum RetryAfter {
    /// RFC 9110: delay-seconds or HTTP-date. A past/invalid value falls back
    /// to the coordinator's backoff. The coordinator applies the safety horizon.
    static func date(_ raw: String?, receivedAt: Date) -> Date? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = TimeInterval(value), seconds.isFinite {
            let date = receivedAt.addingTimeInterval(seconds)
            return date.timeIntervalSinceReferenceDate.isFinite && date > receivedAt ? date : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        // Accept IMF-fixdate and the two obsolete HTTP-date formats too.
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'",
                       "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value), date > receivedAt { return date }
        }
        return nil
    }
}

/// A single fetch includes all transport retries. HTTP failures never retry
/// here: the coordinator controls when another provider fetch is eligible.
enum HTTPClient {
    typealias RetryScheduler = (TimeInterval, @escaping () -> Void) -> Void

    static func get(_ request: URLRequest, attempt: Int = 1,
                    session: URLSession = .shared,
                    now: @escaping () -> Date = Date.init,
                    scheduleRetry: @escaping RetryScheduler = { delay, work in
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
                    },
                    log: @escaping (String) -> Void = { _ in },
                    completion: @escaping (Result<Data, UsageError>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if let error {
                let delays: [TimeInterval] = [3, 10]
                if attempt <= delays.count {
                    scheduleRetry(delays[attempt - 1]) {
                        get(request, attempt: attempt + 1, session: session, now: now,
                            scheduleRetry: scheduleRetry, log: log, completion: completion)
                    }
                    return
                }
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                switch http.statusCode {
                case 401, 403: completion(.failure(.unauthorized("re-login and retry")))
                case 429:
                    let raw = http.value(forHTTPHeaderField: "Retry-After")
                    let date = RetryAfter.date(raw, receivedAt: now())
                    // Log only this header, bounded and with control characters
                    // removed. Authorization and response bodies stay private.
                    let safe = raw.map { value in
                        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                            .map(String.init).joined().prefix(120))
                    } ?? "absent"
                    log("HTTP 429; Retry-After=\(safe); parsed=\(date.map(String.init(describing:)) ?? "fallback")")
                    completion(.failure(.rateLimited(retryAfter: date)))
                default: completion(.failure(.http(http.statusCode)))
                }
                return
            }
            guard let data else { completion(.failure(.malformedResponse)); return }
            completion(.success(data))
        }.resume()
    }
}
