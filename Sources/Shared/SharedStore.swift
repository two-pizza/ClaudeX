import Foundation

/// The bridge between the menu bar app and the widget.
///
/// A widget extension is sandboxed and cannot reach the Keychain, run
/// /usr/bin/security, or read arbitrary files - so it never fetches anything
/// itself. The app writes the latest snapshot into the shared App Group
/// container and asks WidgetKit to reload; the widget only ever reads.
///
/// Only rendered numbers cross this boundary. Tokens never do: a file in the
/// group container is readable by every process carrying the entitlement,
/// which is a far weaker guarantee than the Keychain.
enum SharedStore {

    /// On macOS an App Group identifier must carry the team prefix;
    /// on iOS it must not. Same group, two spellings.
    static let appGroup: String = {
        #if os(macOS)
        return "Q88AAT3T5N.group.me.andrey.ClaudeX"
        #else
        return "group.me.andrey.ClaudeX"
        #endif
    }()

    /// What the widget renders. Errors are carried as text rather than as
    /// UsageError so the widget needs no knowledge of the fetching layer.
    struct Payload: Codable, Hashable {
        var snapshot: CombinedSnapshot
        var errors: [String: String]
        var writtenAt: Date

        /// True when every provider failed and nothing usable came back.
        var isEmpty: Bool { snapshot.providers.isEmpty }
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent("usage-snapshot.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes the snapshot for the widget. Returns false when the App Group
    /// container is unavailable - which is the normal case for an ad-hoc build
    /// without the entitlement, and must not be treated as an error.
    @discardableResult
    static func write(snapshot: CombinedSnapshot, errors: [String: String]) -> Bool {
        guard let fileURL else { return false }
        let payload = Payload(snapshot: snapshot, errors: errors, writtenAt: Date())
        guard let data = try? encoder.encode(payload) else { return false }
        // Atomic: the widget may read while we write.
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    static func read() -> Payload? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(Payload.self, from: data)
    }
}
