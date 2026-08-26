import Foundation
import MediaPlayer
import UIKit

/// Lock screen, Control Center, CarPlay and hardware-button integration.
///
/// Split out of the engine so the remote-command wiring happens exactly once.
/// The previous version added command targets in `init` without ever removing
/// them, and refetched the artwork image over the network on every 0.5-second
/// tick — twice a second, for the entire duration of playback.
@MainActor
final class NowPlayingController {

    private weak var engine: PlayerEngine?

    private var info: [String: Any] = [:]
    /// Artwork is fetched once per artwork URL and cached for the session.
    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    private var artworkTask: Task<Void, Never>?
    private var commandsConfigured = false

    func attach(engine: PlayerEngine) {
        self.engine = engine
        configureCommandsOnce()
    }

    // MARK: - Remote commands

    private func configureCommandsOnce() {
        guard !commandsConfigured else { return }
        commandsConfigured = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            engine.play()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            engine.pause()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            engine.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            guard engine.canGoNext else { return .commandFailed }
            engine.next()
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            guard engine.canGoPrevious else { return .commandFailed }
            engine.previous()
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            engine.skipForward(30)
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            engine.skipBackward(15)
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let engine = self?.engine,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            engine.seek(to: event.positionTime)
            return .success
        }

        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1.0, 1.25, 1.5, 2.0]
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let engine = self?.engine,
                  let event = event as? MPChangePlaybackRateCommandEvent
            else { return .commandFailed }
            engine.setPlaybackSpeed(Float(event.playbackRate))
            return .success
        }
    }

    // MARK: - Metadata

    func update(item: MediaItem, duration: TimeInterval, engine: PlayerEngine) {
        info = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.author,
            MPNowPlayingInfoPropertyMediaType: item.kind == .video
                ? MPNowPlayingInfoMediaType.video.rawValue
                : MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        if let album = item.detail {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        let effectiveDuration = duration.isFinite && duration > 0 ? duration : item.duration
        if effectiveDuration.isFinite, effectiveDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = effectiveDuration
        }

        if let cached = item.artworkURL.flatMap({ artworkCache[$0] }) {
            info[MPMediaItemPropertyArtwork] = cached
        }

        commit(engine: engine)
        loadArtworkIfNeeded(for: item)
    }

    /// Cheap update for play/pause/seek. Rebuilding the whole dictionary and
    /// re-downloading artwork on every tick was the old behaviour.
    func refreshPlaybackState() {
        guard let engine, engine.currentItem != nil, !info.isEmpty else { return }
        commit(engine: engine)
    }

    private func commit(engine: PlayerEngine) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPlaying ? engine.playbackSpeed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        artworkTask?.cancel()
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func loadArtworkIfNeeded(for item: MediaItem) {
        guard let url = item.artworkURL, artworkCache[url] == nil else { return }

        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let data = try? await HTTPClient.shared.data(from: url),
                  let image = UIImage(data: data),
                  !Task.isCancelled
            else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

            guard let self, let engine = self.engine else { return }
            self.artworkCache[url] = artwork

            // Only apply if the track hasn't changed while downloading.
            guard engine.currentItem?.artworkURL == url else { return }
            self.info[MPMediaItemPropertyArtwork] = artwork
            self.commit(engine: engine)
        }
    }
}
