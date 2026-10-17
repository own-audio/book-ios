import ActivityKit
import AppIntents
import Foundation

/// The player's Live Activity: what the lock screen and the Dynamic Island show while a book
/// plays. The attributes are fixed for the book; the state moves with the position.
struct BookActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var chapter: String?
        var positionMs: Int64
        var durationMs: Int64
        var isPlaying: Bool
        var rate: Float
        /// When `positionMs` was true, so the view can count on while playing.
        var at: Date
        /// A JPEG in the App Group container, by file name. In the state rather than the
        /// attributes: the cover often arrives after the activity has started, and only the
        /// state can change.
        var coverFile: String?
    }

    /// The composite book id, as `ownbook://play/<id>` wants it.
    let bookId: String
    let title: String
    let author: String

    static let appGroup = "group.audio.own.bookplayer"

    static func coverURL(file: String?) -> URL? {
        guard let file else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(file)
    }
}

/// The Live Activity's buttons. iOS runs the intent in the app, where `handler` is set; the
/// widget extension only names the type.
struct PlaybackControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control Playback"
    static let isDiscoverable = false

    enum Action: String, AppEnum {
        case toggle, back, forward
        static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Action")
        static let caseDisplayRepresentations: [Action: DisplayRepresentation] = [
            .toggle: "Play or Pause", .back: "Skip Back", .forward: "Skip Forward",
        ]
    }

    @Parameter(title: "Action")
    var action: Action

    init() {}
    init(_ action: Action) { self.action = action }

    /// Set by the app at launch; nil in the widget extension.
    nonisolated(unsafe) static var handler: (@MainActor (Action) async -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        await Self.handler?(action)
        return .result()
    }
}
