import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the Continue Listening widget shows: the app writes it into the App Group when the home
/// screen loads, on play and pause and when the book changes; the widget only reads. Covers travel as small JPEGs,
/// so the widget never needs the network or a sign-in.
struct WidgetSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        /// The composite book id, as `ownbook://play/<id>` wants it.
        let id: String
        let title: String
        let author: String
        /// 0…1 of the book listened to.
        let fraction: Double
        let remainingMs: Int64
        let cover: Data?
    }

    var entries: [Entry]
    var at: Date

    static let appGroup = "group.audio.own.bookplayer"
    static let scheme = "ownbook"

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("continue-listening.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Whether this differs from what was saved in what the widget shows. `at` is left out: it
    /// changes on every write, and counting it would redraw the widget each time.
    func differs(from saved: WidgetSnapshot?) -> Bool {
        saved?.entries != entries
    }

    /// Writes the snapshot and asks the widgets to redraw; nothing happens when it is unchanged.
    func save() {
        guard let file = Self.file, differs(from: Self.load()), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: .atomic)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// The link a tap opens: the composite id carries a `|`, which has to be escaped in a path.
    static func playURL(for id: String) -> URL? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "\(scheme)://play/\(escaped)")
    }

    /// The id back out of such a link, or nil for any other link.
    static func bookId(from url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "play" else { return nil }
        return url.lastPathComponent.removingPercentEncoding
    }
}
