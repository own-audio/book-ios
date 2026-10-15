import Foundation
import MediaPlayer

#if os(iOS)
import AVFoundation
import UIKit
public typealias NowPlayingImage = UIImage
#elseif os(macOS)
import AppKit
public typealias NowPlayingImage = NSImage
#endif

/// Lock screen, Control Center, headphone buttons and CarPlay's Now Playing, through
/// `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`; on iOS also the audio session for
/// background playback.
///
/// `MPRemoteCommandCenter` is a system-wide singleton and `addTarget` adds rather than replaces,
/// so there must be exactly one of these per app; the engine re-points the closures instead.
@MainActor
public final class NowPlayingController {
    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onSeek: ((TimeInterval) -> Void)?
    public var onNextTrack: (() -> Void)?
    public var onPreviousTrack: (() -> Void)?
    /// Spoken-word players: the lock screen shows skip buttons with these intervals in place of
    /// next/previous (`configureSkips`).
    public var onSkipForward: ((TimeInterval) -> Void)?
    public var onSkipBackward: ((TimeInterval) -> Void)?

    private let commandCenter = MPRemoteCommandCenter.shared()

    public init() {
        configureAudioSession()
        configureRemoteCommands()
    }

    private func configureAudioSession() {
        #if os(iOS)
        // `.default`, not `.spokenAudio`: the latter applies speech processing music doesn't want.
        // Playback still works without it; only background and lock-screen integration would suffer.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif
    }

    /// Takes the audio over from other apps. Called when playback starts, not at launch: opening
    /// the app to browse must not stop what another app is playing.
    public func activateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// For books and podcasts: `.spokenAudio` lets the system treat the audio as speech (its
    /// ducking rules, the Siri and navigation mix), `.longFormAudio` routes it like a book on
    /// AirPlay 2 and the HomePod. Called by the spoken engine before its first play.
    public func useSpokenAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        #endif
    }

    /// Shows skip buttons with these intervals on the lock screen and in CarPlay's Now Playing
    /// (next/previous stay for chapters where the engine says there are any).
    public func configureSkips(forwardSecs: Double, backwardSecs: Double) {
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: forwardSecs)]
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: backwardSecs)]
    }

    /// Asks for the track's own rate above 48 kHz. The route decides: a USB DAC can run that
    /// fast, Bluetooth usually can't. `sessionSampleRate` reads back what was granted.
    public func preferSampleRate(_ sampleRate: Double) {
        #if os(iOS)
        guard sampleRate > 48000 else { return }
        try? AVAudioSession.sharedInstance().setPreferredSampleRate(sampleRate)
        #endif
    }

    public var sessionSampleRate: Double? {
        #if os(iOS)
        AVAudioSession.sharedInstance().sampleRate
        #else
        nil
        #endif
    }

    private func configureRemoteCommands() {
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.onPlay?()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let playing = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float ?? 0) > 0
            playing ? self.onPause?() : self.onPlay?()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek?(event.positionTime)
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextTrack?()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPreviousTrack?()
            return .success
        }
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let onSkipForward else { return .commandFailed }
            onSkipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? 30)
            return .success
        }
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let onSkipBackward else { return .commandFailed }
            onSkipBackward((event as? MPSkipIntervalCommandEvent)?.interval ?? 15)
            return .success
        }
    }

    public func update(
        title: String, artist: String?, album: String?, duration: Double, elapsedTime: Double,
        rate: Float, artwork: NowPlayingImage?, hasNextTrack: Bool, hasPreviousTrack: Bool
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork {
            // The system calls this handler off the main actor (CarPlay does, at least). A
            // closure written here would inherit main-actor isolation and trap at runtime, so
            // it is made explicitly `@Sendable`; a finished image is safe to read from any thread.
            nonisolated(unsafe) let boxedArtwork = artwork
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { @Sendable _ in boxedArtwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        commandCenter.nextTrackCommand.isEnabled = hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = hasPreviousTrack
    }

    public func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }
}
