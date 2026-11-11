import Foundation

/// Asks GitHub for the latest published release and compares it with the
/// running version. It never downloads or replaces anything: installing stays
/// a manual step, so a compromised release page cannot swap the app that
/// holds the Claude token.
enum UpdateCheck {
    static let latestURL = URL(string: "https://api.github.com/repos/two-pizza/ClaudeX/releases/latest")!
    /// The background check runs at most this often.
    static let interval: TimeInterval = 24 * 3600

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        /// The menu bar zip attached to the release, if any.
        let downloadURL: URL?
    }

    enum Outcome: Equatable {
        case upToDate(current: String)
        case available(Release)
        case failed(String)
    }

    private struct Response: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
        let tagName: String
        let htmlUrl: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    /// Parses the /releases/latest body. GitHub already skips drafts and
    /// pre-releases there; they are rejected again in case that changes.
    static func release(from data: Data) -> Release? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: data),
              response.draft != true, response.prerelease != true,
              let version = version(fromTag: response.tagName),
              isGitHubPage(response.htmlUrl) else { return nil }
        let zip = response.assets?.first {
            $0.name.hasSuffix("-menubar.zip") && isGitHubPage($0.browserDownloadUrl)
        }
        return Release(version: version, pageURL: response.htmlUrl,
                       downloadURL: zip?.browserDownloadUrl)
    }

    /// "v1.2.5" -> "1.2.5". Anything that is not plain numeric parts is refused.
    static func version(fromTag tag: String) -> String? {
        let raw = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return components(raw) == nil ? nil : raw
    }

    /// True when `candidate` is a strictly higher version than `current`.
    /// Missing trailing parts count as zero, so 1.3 == 1.3.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func outcome(data: Data, current: String) -> Outcome {
        guard let release = release(from: data) else {
            return .failed("Could not read the latest release")
        }
        return isNewer(release.version, than: current) ? .available(release)
                                                       : .upToDate(current: current)
    }

    static func fetch(current: String, session: URLSession = .shared,
                      completion: @escaping (Outcome) -> Void) {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeX/\(current)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { data, response, error in
            let outcome: Outcome
            if let error {
                outcome = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                outcome = .failed("GitHub returned \(http.statusCode)")
            } else {
                outcome = Self.outcome(data: data ?? Data(), current: current)
            }
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    /// The URL is handed to NSWorkspace.open, which picks a handler by scheme,
    /// so only an https link on github.com itself may reach it.
    private static func isGitHubPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

/// One update check at a time for the whole app. A manual check that arrives
/// while a quiet one is running joins it and shows its result; clicks while a
/// request or the result dialog is open are ignored. With a single request in
/// flight, an older answer can never overwrite a newer one.
final class UpdateChecker {
    typealias Fetch = (@escaping (UpdateCheck.Outcome) -> Void) -> Void

    private let fetch: Fetch
    /// Every result, quiet or manual - keeps the menu item current.
    var onResult: (UpdateCheck.Outcome) -> Void = { _ in }
    /// Shows a manual check's result; call `done` once the dialog is closed.
    var present: (UpdateCheck.Outcome, _ done: @escaping () -> Void) -> Void = { _, done in done() }

    private(set) var isChecking = false
    private var wantsDialog = false
    private var isPresenting = false

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    func check(manual: Bool) {
        if manual {
            guard !isPresenting else { return }
            wantsDialog = true
        }
        guard !isChecking else { return }
        isChecking = true
        fetch { [weak self] outcome in
            guard let self else { return }
            self.isChecking = false
            self.onResult(outcome)
            guard self.wantsDialog else { return }
            self.wantsDialog = false
            self.isPresenting = true
            self.present(outcome) { [weak self] in self?.isPresenting = false }
        }
    }
}
