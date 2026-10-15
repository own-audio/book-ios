import Foundation

/// How far to go back when playback resumes after a pause: nothing after a short one, up to
/// half a minute after hours, because the listener has lost the thread by then. The steps are
/// the ones most audiobook players settled on.
public struct SmartRewind: Sendable, Equatable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    /// Milliseconds to rewind after `seconds` of pause.
    public func rewindMs(pausedFor seconds: TimeInterval) -> Int64 {
        guard isEnabled else { return 0 }
        switch seconds {
        case ..<10: return 0
        case ..<60: return 3_000
        case ..<600: return 10_000
        case ..<3600: return 20_000
        default: return 30_000
        }
    }
}
