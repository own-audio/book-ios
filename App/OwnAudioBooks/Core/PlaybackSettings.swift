import Foundation
import Observation

/// The listener's playback preferences, in UserDefaults: skip intervals, the speed books start
/// at (each book remembers its own after that), smart rewind, and what to do on mobile data.
@Observable
@MainActor
final class PlaybackSettings {
    enum MobileData: String, CaseIterable {
        /// Stream the original files.
        case original
        /// Ask the server for a smaller stream where it makes one.
        case saver
        /// Play only what is downloaded.
        case downloadedOnly
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skipForwardSecs = defaults.object(forKey: "playback.skipForward") as? Double ?? 30
        skipBackwardSecs = defaults.object(forKey: "playback.skipBackward") as? Double ?? 15
        defaultRate = defaults.object(forKey: "playback.defaultRate") as? Float ?? 1.0
        smartRewind = defaults.object(forKey: "playback.smartRewind") as? Bool ?? true
        mobileData = MobileData(rawValue: defaults.string(forKey: "playback.mobileData") ?? "") ?? .original
        bookRates = (defaults.dictionary(forKey: "playback.bookRates") as? [String: Float]) ?? [:]
    }

    var skipForwardSecs: Double { didSet { defaults.set(skipForwardSecs, forKey: "playback.skipForward") } }
    var skipBackwardSecs: Double { didSet { defaults.set(skipBackwardSecs, forKey: "playback.skipBackward") } }
    var defaultRate: Float { didSet { defaults.set(defaultRate, forKey: "playback.defaultRate") } }
    var smartRewind: Bool { didSet { defaults.set(smartRewind, forKey: "playback.smartRewind") } }
    var mobileData: MobileData { didSet { defaults.set(mobileData.rawValue, forKey: "playback.mobileData") } }
    /// Per book (composite id): the speed it was last played at.
    private(set) var bookRates: [String: Float]

    static let skipChoices: [Double] = [5, 10, 15, 30, 45, 60, 90]
    /// The saver stream's bitrate in kbps; enough for speech.
    static let saverBitrateKbps = 64

    func rate(for compositeId: String) -> Float {
        bookRates[compositeId] ?? defaultRate
    }

    func remember(rate: Float, for compositeId: String) {
        bookRates[compositeId] = rate
        defaults.set(bookRates, forKey: "playback.bookRates")
    }
}
