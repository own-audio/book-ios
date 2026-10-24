import Foundation

/// What the engine does when the network runs out under it: "No signal — waiting" rather than
/// a failure, and on by itself when the signal returns — if the listener was listening and did
/// not pause meanwhile.
///
/// Two ways to come back. While the player item is intact (`hold`: the look-ahead window ran
/// out, or a stream stalled with no network) the player is left waiting rather than paused —
/// an audio app whose player is paused is suspended in the background, and could not come back
/// by itself; the window keeps trying (2 s doubling to 30 s) and says when bytes come again
/// (`fed`). When the item has failed, or a part is not on the phone, it is loaded again from a
/// fresh link (`reload`), tried with the same backoff.
struct SignalWait: Equatable, Sendable {
    enum Way: Equatable, Sendable {
        case hold
        case reload
    }

    enum Event: Equatable, Sendable {
        /// The player has nothing to play and the network can't bring it.
        case lost(Way, wasPlaying: Bool)
        /// The window's bytes flow again.
        case fed
        /// A reload worked.
        case reloaded
        /// The network is back (the app's network monitor).
        case networkReturned
        case userPaused
        case userPlayed
        /// Something else ended it: a seek, another book, a stop.
        case reset
    }

    enum Action: Equatable, Sendable {
        case none
        /// Report the position, stop counting listening time, show the waiting state; a failed
        /// item is paused.
        case pause
        /// Play again from where it stopped (and ask the window to try now).
        case resume
        /// Try a reload now.
        case reloadNow
        /// Ask the window to try now.
        case nudgeWindow
    }

    private(set) var way: Way?
    /// Plays on by itself when the signal returns.
    private(set) var resumes = false

    var isWaiting: Bool { way != nil }

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .lost(let lostWay, let wasPlaying):
            if let way {
                // A reload outranks the window: the item itself has failed.
                if lostWay == .reload, way == .hold { self.way = .reload }
                return .none
            }
            way = lostWay
            resumes = wasPlaying
            return wasPlaying ? .pause : .none
        case .fed:
            guard way == .hold else { return .none }
            way = nil
            return resumes ? .resume : .none
        case .reloaded:
            guard way != nil else { return .none }
            way = nil
            // The reload itself plays when it should.
            return .none
        case .networkReturned:
            switch way {
            case .reload:
                return .reloadNow
            case .hold:
                // The item is intact: playing asks the window again. Should the bytes still
                // not come, the player stalls and this starts over.
                way = nil
                return resumes ? .resume : .nudgeWindow
            case nil:
                return .none
            }
        case .userPaused:
            resumes = false
            return .none
        case .userPlayed:
            guard let way else { return .none }
            resumes = true
            if way == .reload { return .reloadNow }
            // The item is intact: it plays what it can, and stalls again if nothing comes.
            self.way = nil
            return .nudgeWindow
        case .reset:
            way = nil
            resumes = false
            return .none
        }
    }
}
