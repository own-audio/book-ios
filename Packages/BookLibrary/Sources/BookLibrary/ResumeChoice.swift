import Foundation

/// Where to start a book when this phone and the server disagree: the server's position is
/// another device's and well ahead of (or behind) what this phone last knew — then the
/// listener is asked, because either place may be the right one (the car went on without
/// them, or they rewound on purpose here).
public enum ResumeChoice: Sendable, Equatable {
    /// Start at `positionMs`, no question.
    case start(positionMs: Int64)
    /// Ask: this phone's position, and the other device's with its name.
    case ask(localMs: Int64, otherMs: Int64, otherDevice: String?)

    /// `local` is what this phone last saved (nil when it never played the book), `server` the
    /// server's answer. Positions closer than `toleranceMs` are the same place.
    public static func decide(local: ListeningProgress?, server: ListeningProgress?, toleranceMs: Int64 = 30_000) -> ResumeChoice {
        guard let server else { return .start(positionMs: local?.finished == true ? 0 : local?.positionMs ?? 0) }
        if server.finished { return .start(positionMs: 0) }
        guard let local, !local.finished, abs(local.positionMs - server.positionMs) > toleranceMs else {
            return .start(positionMs: server.positionMs)
        }
        // The server's position is another device's when one of its device entries sits
        // there and is newer than what this phone saved.
        let other = server.devices.first { !$0.isThisDevice && abs($0.positionMs - server.positionMs) <= toleranceMs && $0.at > local.updatedAt }
        guard let other else { return .start(positionMs: server.updatedAt > local.updatedAt ? server.positionMs : local.positionMs) }
        return .ask(localMs: local.positionMs, otherMs: server.positionMs, otherDevice: other.name ?? other.kind)
    }
}
