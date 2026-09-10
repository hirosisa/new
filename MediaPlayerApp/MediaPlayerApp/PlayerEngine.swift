import Foundation
import AVFoundation
import Combine
import MediaPlayer
import MediaToolbox

/// Defined at file scope because a stored-property initialiser may not reference
/// `Self` — "covariant 'Self' type cannot be referenced from a stored property
/// initializer" — even when the enclosing class is `final`.
private let audioOnlyDefaultsKey = "preferAudioOnly"
private let volumeBoostDefaultsKey = "volumeBoost"

/// Scales an item's audio above unity through an MTAudioProcessingTap — the
/// only way `AVPlayer` can exceed 100%. CoreMedia honors taps for local-file
/// playback (downloads, imported files); streaming HLS ignores them, so the
/// boost is applied only where it can actually work.
enum VolumeBoost {
    private final class Box {
        let gain: Float
        init(_ gain: Float) { self.gain = gain }
    }

    /// No-op below unity: taps have a cost and 100% needs none.
    static func apply(to item: AVPlayerItem, gain: Float) {
        guard gain > 1.001 else { return }
        Task {
            guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio),
                  let track = tracks.first else { return }

            let box = Unmanaged.passRetained(Box(gain)).toOpaque()
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: box,
                init: tapInit,
                finalize: tapFinalize,
                prepare: nil,
                unprepare: nil,
                process: tapProcess
            )
            var tapOut: Unmanaged<MTAudioProcessingTap>?
            let status = MTAudioProcessingTapCreate(
                kCFAllocatorDefault,
                &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects,
                &tapOut
            )
            guard status == noErr, let tap = tapOut else {
                Unmanaged<Box>.fromOpaque(box).release()
                return
            }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap.takeRetainedValue()
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }

    private static func tapInit(
        _ tap: MTAudioProcessingTap,
        clientInfo: UnsafeMutableRawPointer?,
        tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) {
        tapStorageOut.pointee = clientInfo
    }

    private static func tapFinalize(_ tap: MTAudioProcessingTap) {
        Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
    }

    private static func tapProcess(
        _ tap: MTAudioProcessingTap,
        numberFrames: CMItemCount,
        flags: MTAudioProcessingTapFlags,
        bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
    ) {
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferListInOut,
            flagsOut,
            nil,
            numberFramesOut
        )
        guard status == noErr else { return }

        let gain = Unmanaged<Box>
            .fromOpaque(MTAudioProcessingTapGetStorage(tap))
            .takeUnretainedValue().gain
        for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else { continue }
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<count { samples[i] *= gain }
        }
    }
}

/// Playback engine: one long-lived `AVPlayer`, a queue, and lock-screen integration.
///
/// Design notes, each fixing a concrete defect in the previous version:
///
///  * **One player for the app's lifetime.** Items are swapped with
///    `replaceCurrentItem(with:)`. Previously a new `AVPlayer` was constructed per
///    track while the periodic time observer was removed from the *new* player,
///    so the old player kept its observer forever — a leak, and `removeTimeObserver`
///    on a foreign player traps.
///  * **Combine instead of manual KVO.** The old code called `addObserver` on every
///    `AVPlayerItem` and only ever removed the last one, which crashes with
///    "deallocated while key value observers were still registered".
///  * **`@MainActor`.** All published state is mutated on the main actor, so SwiftUI
///    never reads a torn value.
///  * **NaN-safe.** `AVPlayer` reports `NaN` duration until an item is ready;
///    feeding that into a SwiftUI frame crashes the render pass.
///  * **Artwork fetched once per item**, not on every 0.5s tick.
///  * **Repeat-off actually stops** at the end of the queue instead of wrapping.
@MainActor
final class PlayerEngine: ObservableObject {

    // MARK: Published state

    @Published private(set) var currentItem: MediaItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var currentIndex = 0

    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var isShuffled = false
    /// Persisted: someone using this mainly for music wants audio-only every
    /// launch, not a video stream chewing through data until they remember to
    /// toggle it.
    @Published private(set) var audioOnly = UserDefaults.standard.object(forKey: audioOnlyDefaultsKey) as? Bool ?? true
    @Published private(set) var playbackSpeed: Float = 1.0
    /// Audio gain above unity (1.0 = 100%). Applied to local-file playback;
    /// streaming HLS ignores taps, so streams stay at system volume.
    @Published private(set) var volumeBoost: Float =
        UserDefaults.standard.object(forKey: volumeBoostDefaultsKey) as? Float ?? 1.0

    static let audioOnlyKey = audioOnlyDefaultsKey

    /// Remaining seconds on the sleep timer, or `nil` when off.
    @Published private(set) var sleepTimerRemaining: TimeInterval?

    /// Exposed read-only so the video surface can attach an `AVPlayerLayer`.
    /// The engine still owns it; views never mutate it.
    let player = AVPlayer()

    var canGoNext: Bool { !queue.isEmpty && (repeatMode != .off || currentIndex < queue.count - 1) }
    var canGoPrevious: Bool { !queue.isEmpty }
    var hasVideo: Bool { currentItem?.kind == .video && !audioOnly }

    var progress: Double { Formatters.progress(current: currentTime, duration: duration) }

    // MARK: Private

    private let registry: SourceRegistry
    private let nowPlaying = NowPlayingController()

    private var timeObserver: Any?
    private var itemCancellables = Set<AnyCancellable>()
    private var playerCancellables = Set<AnyCancellable>()

    private var loadTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    /// Cancels the HLS “never started” fallback when playback actually begins.
    private var stallTask: Task<Void, Never>?
    /// Last URL handed to AVPlayer, so a stall/failure can skip HLS next time.
    private var lastAttachedURL: URL?

    /// Playback order when shuffled: indices into `queue`.
    private var shuffleOrder: [Int] = []
    /// Guards against an infinite retry loop when a stream URL has expired.
    private var retriedCurrentItem = false

    /// Takes an optional rather than defaulting to `.shared`: default argument
    /// expressions are evaluated in a nonisolated context, and reaching a
    /// `@MainActor` static property from there is an error under Swift 6.
    /// Resolving it inside the initialiser keeps it on the main actor.
    init(registry: SourceRegistry? = nil) {
        self.registry = registry ?? .shared

        configureAudioSession()
        observePlayer()
        addPeriodicTimeObserver()
        observeNotifications()
        nowPlaying.attach(engine: self)
    }

    deinit {
        // `player` is owned here and outlives nothing, but the observer must
        // still be detached from the exact player it was added to.
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    // MARK: - Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: - Observation

    private func observePlayer() {
        // Drive `isPlaying` from the player's own status rather than guessing,
        // so lock-screen and interruption-driven changes stay in sync.
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = (status == .playing)
                if status == .playing {
                    self.errorMessage = nil
                    self.stallTask?.cancel()
                }
                self.nowPlaying.refreshPlaybackState()
            }
            .store(in: &playerCancellables)
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // AVFoundation types this callback as @Sendable, so touching
            // main-actor state inside it is a concurrency error under Swift 6.
            // It is registered on the main queue, so the isolation is real —
            // `assumeIsolated` asserts that without an actor hop.
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                self.currentTime = seconds.isFinite ? max(0, seconds) : 0

                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }
    }

    private func observeNotifications() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &playerCancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleRouteChange(note) }
            .store(in: &playerCancellables)
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            pause()
        case .ended:
            guard let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                // The session goes inactive during an interruption; reactivate
                // before resuming or `play()` is a silent no-op.
                try? AVAudioSession.sharedInstance().setActive(true)
                play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            pause() // Headphones pulled out.
        }
    }

    // MARK: - Loading

    /// Starts playback of `item`, optionally replacing the queue.
    func play(item: MediaItem, in queue: [MediaItem] = [], autoPlay: Bool = true) {
        let newQueue = queue.isEmpty ? [item] : queue
        let index = newQueue.firstIndex(of: item) ?? 0

        self.queue = newQueue
        self.currentIndex = index
        if isShuffled { rebuildShuffleOrder(startingAt: index) }

        load(newQueue[index], autoPlay: autoPlay)
    }

    private func load(_ item: MediaItem, autoPlay: Bool, resumeAt: TimeInterval? = nil) {
        loadTask?.cancel()
        stallTask?.cancel()

        currentItem = item
        errorMessage = nil
        isLoading = true
        currentTime = resumeAt ?? 0
        duration = item.duration.isFinite ? item.duration : 0
        retriedCurrentItem = false

        loadTask = Task { [weak self] in
            guard let self else { return }

            do {
                let url = try await self.resolveStreamURL(for: item)
                if Task.isCancelled { return }
                self.attach(url: url, for: item, autoPlay: autoPlay, resumeAt: resumeAt)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.isLoading = false
                self.errorMessage = diagnosticDescription(of: error)
            }
        }
    }

    /// `localizedDescription` alone often reads "An unknown error occurred"
    /// (AVFoundation's AVErrorUnknown), which is undiagnosable from a phone
    /// with no console attached. Appending the NSError domain and code makes
    /// the on-screen message actionable.
    private func diagnosticDescription(of error: Error) -> String {
        let ns = error as NSError
        let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(base) [\(ns.domain) \(ns.code)]"
    }

    private func resolveStreamURL(for item: MediaItem) async throws -> URL {
        // Downloaded items play from disk first: they never expire and work
        // offline. `localFile` picks the format matching the current mode.
        if let local = DownloadManager.shared.localFile(for: item, audioOnly: audioOnly) {
            return local
        }
        guard let source = registry.source(for: item) else {
            // Fall back to an embedded URL if the source has been removed.
            if let url = item.streamURL { return url }
            throw SourceError.notConfigured("The source for “\(item.title)” is no longer available.")
        }
        return try await source.resolveStream(for: item, preferAudioOnly: audioOnly)
    }

    private func attach(url: URL, for item: MediaItem, autoPlay: Bool, resumeAt: TimeInterval?) {
        itemCancellables.removeAll() // Detaches observers from the previous item.

        // Only documented AVURLAsset option keys are used here. Custom request
        // headers would need AVAssetResourceLoader; none of the working sources
        // require them.
        let asset = AVURLAsset(url: url)
        // NOTE: AVURLAssetPreferPreciseDurationAndTimingKey was removed: with HLS
        // streams it forces a full manifest crawl before the item reports
        // readyToPlay, which can leave the player stuck at --:-- on device.
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 5
        // >100% gain is honored for local files; streams ignore taps.
        if url.isFileURL {
            VolumeBoost.apply(to: playerItem, gain: volumeBoost)
        }

        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                // A retry leaves the old item's observers attached for a while;
                // its late events must not clobber the retry's state.
                guard self?.player.currentItem === playerItem else { return }
                self?.handle(status: status, for: playerItem, item: item, autoPlay: autoPlay, resumeAt: resumeAt)
            }
            .store(in: &itemCancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.player.currentItem === playerItem else { return }
                self?.handlePlaybackEnded()
            }
            .store(in: &itemCancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.player.currentItem === playerItem else { return }
                self?.retryOrFail(item: item)
            }
            .store(in: &itemCancellables)

        player.replaceCurrentItem(with: playerItem)
        // `defaultRate` (iOS 16+) makes `play()` resume at the chosen speed
        // instead of snapping back to 1×.
        player.defaultRate = playbackSpeed
        lastAttachedURL = url
        watchForStall(item: item, url: url, autoPlay: autoPlay)

        nowPlaying.update(item: item, duration: duration, engine: self)
    }

    private func handle(status: AVPlayerItem.Status,
                        for playerItem: AVPlayerItem,
                        item: MediaItem,
                        autoPlay: Bool,
                        resumeAt: TimeInterval?) {
        switch status {
        case .readyToPlay:
            isLoading = false

            let assetDuration = playerItem.duration.seconds
            if assetDuration.isFinite, assetDuration > 0 {
                duration = assetDuration
            }

            // When resuming (audio/video toggle, expired-URL retry) start
            // playing only once the seek lands, otherwise the first second
            // plays from zero before jumping.
            if let resumeAt, resumeAt > 0 {
                let ceiling = duration > 0 ? duration : resumeAt
                let clamped = min(resumeAt, ceiling)
                player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.currentTime = clamped
                        if autoPlay { self.play() }
                    }
                }
            } else if autoPlay {
                play()
            }

            nowPlaying.update(item: item, duration: duration, engine: self)

        case .failed:
            retryOrFail(item: item, error: playerItem.error)

        case .unknown:
            break

        @unknown default:
            break
        }
    }

    /// HLS masters can report readyToPlay then never start (VP9-first manifests).
    /// After 8s with no actual playback, skip HLS and re-resolve as muxed MP4.
    /// Only armed when playback was requested — an item loaded paused
    /// (`autoPlay: false`) is waiting for the user, not stalled. `pause()`
    /// cancels the watch too, so a user pause during buffering or an
    /// audio-session interruption can never trigger the fallback.
    private func watchForStall(item: MediaItem, url: URL, autoPlay: Bool) {
        stallTask?.cancel()
        guard autoPlay, looksLikeHLS(url) else { return }

        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // A pause after playback has actually started is not a stall.
            guard self.currentItem?.id == item.id, !self.isPlaying, self.currentTime < 1 else { return }
            YouTubeSource.disableHLS(for: item)
            self.retryOrFail(item: item)
        }
    }

    private func looksLikeHLS(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8"
            || value.contains(".m3u8")
            || value.contains("manifest/hls")
    }

    /// Podcast and Archive URLs are stable, but Invidious stream URLs expire.
    /// One silent re-resolve covers that without looping. HLS stalls also land
    /// here after `disableHLS`, so the next resolve skips HLS and takes the best
    /// stream the remaining clients offer (muxed for the Android clients).
    private func retryOrFail(item: MediaItem, error: Error? = nil) {
        if item.sourceID == "youtube", let last = lastAttachedURL {
            if looksLikeHLS(last) {
                YouTubeSource.disableHLS(for: item)
            } else if audioOnly {
                // Progressive audio failed on this network path; the rest of
                // the session serves audio over the HLS endpoint instead.
                YouTubeSource.enableHLSAudioFallback()
            }
        }

        guard !retriedCurrentItem else {
            isLoading = false
            errorMessage = error.map(diagnosticDescription) ?? "Couldn't play “\(item.title)”."
            return
        }
        retriedCurrentItem = true
        isLoading = true
        stallTask?.cancel()

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.resolveStreamURL(for: item)
                if Task.isCancelled { return }
                self.attach(url: url, for: item, autoPlay: true, resumeAt: self.currentTime)
            } catch {
                if Task.isCancelled { return }
                self.isLoading = false
                self.errorMessage = diagnosticDescription(of: error)
            }
        }
    }

    // MARK: - Transport

    func play() {
        guard player.currentItem != nil else {
            if let item = currentItem { load(item, autoPlay: true) }
            return
        }
        player.playImmediately(atRate: playbackSpeed)
    }

    func pause() {
        // A deliberate pause — including during initial buffering, from a
        // lock-screen control, or from an audio-session interruption — must
        // never be read as an HLS stall, so disarm the watchdog here as well.
        stallTask?.cancel()
        player.pause()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)

        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = clamped
                self.nowPlaying.refreshPlaybackState()
            }
        }
    }

    func skipForward(_ seconds: TimeInterval = 30) {
        seek(to: currentTime + seconds)
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        seek(to: currentTime - seconds)
    }

    func next(userInitiated: Bool = true) {
        guard !queue.isEmpty else { return }

        // Repeat-one only auto-repeats at natural end; an explicit tap advances.
        if repeatMode == .one && !userInitiated {
            seek(to: 0)
            play()
            return
        }

        guard let index = indexAfter(currentIndex, wrapping: repeatMode != .off || userInitiated) else {
            pause()
            seek(to: 0)
            return
        }

        currentIndex = index
        load(queue[index], autoPlay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }

        // Restart the track first, matching every other player's behaviour.
        if currentTime > 3 {
            seek(to: 0)
            play()
            return
        }

        guard let index = indexBefore(currentIndex) else {
            seek(to: 0)
            return
        }

        currentIndex = index
        load(queue[index], autoPlay: true)
    }

    private func handlePlaybackEnded() {
        currentTime = duration
        next(userInitiated: false)
    }

    // MARK: - Ordering

    private func indexAfter(_ index: Int, wrapping: Bool) -> Int? {
        guard !queue.isEmpty else { return nil }

        if isShuffled {
            guard let position = shuffleOrder.firstIndex(of: index) else {
                return shuffleOrder.first
            }
            let nextPosition = position + 1
            if nextPosition < shuffleOrder.count { return shuffleOrder[nextPosition] }
            guard wrapping else { return nil }
            rebuildShuffleOrder(startingAt: nil)
            return shuffleOrder.first
        }

        let nextIndex = index + 1
        if nextIndex < queue.count { return nextIndex }
        return wrapping ? 0 : nil
    }

    private func indexBefore(_ index: Int) -> Int? {
        guard !queue.isEmpty else { return nil }

        if isShuffled {
            guard let position = shuffleOrder.firstIndex(of: index) else {
                return shuffleOrder.first
            }
            let previous = position - 1
            if previous >= 0 { return shuffleOrder[previous] }
            return shuffleOrder.last
        }

        if index - 1 >= 0 { return index - 1 }
        return queue.count - 1
    }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            rebuildShuffleOrder(startingAt: currentIndex)
        } else {
            shuffleOrder = []
        }
    }

    /// A real shuffled permutation. The previous implementation picked a random
    /// index on every advance, which repeats tracks and never covers the queue.
    private func rebuildShuffleOrder(startingAt index: Int?) {
        var order = Array(queue.indices).shuffled()
        if let index, let position = order.firstIndex(of: index) {
            order.swapAt(0, position)
        }
        shuffleOrder = order
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    // MARK: - Queue editing

    func addToQueue(_ items: [MediaItem]) {
        let fresh = items.filter { candidate in !queue.contains(candidate) }
        guard !fresh.isEmpty else { return }
        queue.append(contentsOf: fresh)
        if isShuffled { rebuildShuffleOrder(startingAt: currentIndex) }
    }

    func playNow(_ item: MediaItem) {
        if let index = queue.firstIndex(of: item) {
            currentIndex = index
            load(item, autoPlay: true)
        } else {
            queue.append(item)
            currentIndex = queue.count - 1
            load(item, autoPlay: true)
        }
        if isShuffled { rebuildShuffleOrder(startingAt: currentIndex) }
    }

    /// Removes every queued track except the one currently playing, so the
    /// queue holds only what the user deliberately added.
    func clearQueue(keepingCurrent: Bool = true) {
        guard keepingCurrent, let current = currentItem else {
            stop()
            return
        }
        queue = [current]
        currentIndex = 0
        if isShuffled { rebuildShuffleOrder(startingAt: 0) }
    }

    func removeFromQueue(atOffsets offsets: IndexSet) {
        let removingCurrent = offsets.contains(currentIndex)
        let currentItemBefore = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil

        queue.remove(atOffsets: offsets)

        if queue.isEmpty {
            stop()
            return
        }

        // Keep pointing at the same track when something above it is removed.
        if removingCurrent {
            currentIndex = min(currentIndex, queue.count - 1)
            load(queue[currentIndex], autoPlay: isPlaying)
        } else if let currentItemBefore, let index = queue.firstIndex(of: currentItemBefore) {
            currentIndex = index
        } else {
            currentIndex = min(currentIndex, queue.count - 1)
        }

        if isShuffled { rebuildShuffleOrder(startingAt: currentIndex) }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let currentItemBefore = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentItemBefore, let index = queue.firstIndex(of: currentItemBefore) {
            currentIndex = index
        }
        if isShuffled { rebuildShuffleOrder(startingAt: currentIndex) }
    }

    func stop() {
        loadTask?.cancel()
        stallTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemCancellables.removeAll()
        lastAttachedURL = nil

        currentItem = nil
        queue = []
        currentIndex = 0
        currentTime = 0
        duration = 0
        isLoading = false
        shuffleOrder = []
        nowPlaying.clear()
    }

    // MARK: - Modes

    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = min(max(0.5, speed), 2.5)
        player.defaultRate = playbackSpeed
        if isPlaying {
            player.rate = playbackSpeed
        }
        nowPlaying.refreshPlaybackState()
    }

    /// 1.0 = 100% system volume; up to 3.0. Applies to local-file playback.
    func setVolumeBoost(_ gain: Float) {
        let clamped = min(max(1.0, gain), 3.0)
        volumeBoost = clamped
        UserDefaults.standard.set(clamped, forKey: volumeBoostDefaultsKey)
    }

    /// Switching between video and audio-only re-resolves the stream and
    /// resumes at the same position instead of restarting.
    func setAudioOnly(_ enabled: Bool) {
        guard audioOnly != enabled else { return }
        audioOnly = enabled
        UserDefaults.standard.set(enabled, forKey: Self.audioOnlyKey)

        guard let item = currentItem else { return }
        load(item, autoPlay: isPlaying, resumeAt: currentTime)
    }

    // MARK: - Sleep timer

    func startSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        let total = TimeInterval(minutes * 60)
        sleepTimerRemaining = total

        sleepTask = Task { [weak self] in
            var remaining = total
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                await MainActor.run { self?.sleepTimerRemaining = max(0, remaining) }
            }
            await MainActor.run {
                self?.pause()
                self?.sleepTimerRemaining = nil
            }
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerRemaining = nil
    }
}
