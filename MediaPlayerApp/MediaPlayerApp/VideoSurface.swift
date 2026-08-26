import SwiftUI
import AVFoundation
import AVKit

/// Hosts the engine's `AVPlayer` in an `AVPlayerLayer`, and owns the
/// Picture-in-Picture controller.
///
/// The layer is the view's backing layer via `layerClass`, so UIKit keeps its
/// frame in sync automatically. The previous version added a sublayer and
/// resized it by hand from `updateUIView`, which lags behind rotation and
/// leaves the video mis-sized during the transition.
struct VideoSurface: UIViewRepresentable {

    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// Set by the view layer to expose PiP availability and control.
    var pipController: (AVPictureInPictureController?) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity

        if AVPictureInPictureController.isPictureInPictureSupported(),
           let controller = AVPictureInPictureController(playerLayer: view.playerLayer) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pip = controller
            view.pipController = controller
            pipController(controller)
        } else {
            pipController(nil)
        }

        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        // Routed through the host view so a SwiftUI update while backgrounded
        // can't undo the detach and re-suspend playback.
        uiView.syncPlayer(player)
        uiView.playerLayer.videoGravity = videoGravity
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var pip: AVPictureInPictureController?
    }

    /// Using the backing layer avoids all manual frame bookkeeping.
    ///
    /// It also owns the background/foreground handoff that keeps audio playing
    /// when the screen locks. iOS suspends playback for a player that still has
    /// a video layer attached when the app leaves the foreground — declaring the
    /// `audio` background mode is necessary but not sufficient. Detaching the
    /// player from the layer drops the video output, and audio continues.
    final class PlayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        /// Picture-in-Picture deliberately keeps rendering in the background, so
        /// the layer must stay attached while it's active.
        weak var pipController: AVPictureInPictureController?

        private var observers: [NSObjectProtocol] = []
        /// Held across backgrounding so the exact same player can be restored.
        private var detachedPlayer: AVPlayer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, observers.isEmpty else { return }

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.detachForBackground() }
            )
            observers.append(
                center.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.reattachForForeground() }
            )
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Attaches `player` unless we're currently detached for backgrounding,
        /// in which case it's recorded for restoration instead.
        func syncPlayer(_ player: AVPlayer) {
            if detachedPlayer != nil {
                detachedPlayer = player
                return
            }
            if playerLayer.player !== player {
                playerLayer.player = player
            }
        }

        private func detachForBackground() {
            guard pipController?.isPictureInPictureActive != true,
                  let player = playerLayer.player else { return }

            // The engine holds the strong reference, so this only releases the
            // video output — playback itself is unaffected.
            detachedPlayer = player
            playerLayer.player = nil
        }

        private func reattachForForeground() {
            guard let player = detachedPlayer else { return }
            playerLayer.player = player
            detachedPlayer = nil
        }
    }
}

/// Holds the PiP controller so SwiftUI can drive it from a button.
@MainActor
final class PiPCoordinator: ObservableObject {
    @Published var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private weak var controller: AVPictureInPictureController?

    func adopt(_ controller: AVPictureInPictureController?) {
        self.controller = controller

        // `adopt` is called from `makeUIView`, i.e. during a SwiftUI update.
        // Mutating published state synchronously there triggers the
        // "Publishing changes from within view updates" warning, so the flag is
        // set on the next runloop turn.
        let supported = controller != nil
        Task { @MainActor [weak self] in
            guard let self, self.isSupported != supported else { return }
            self.isSupported = supported
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }
}

/// System AirPlay picker. The old UI drew a static `airplayaudio` glyph that
/// wasn't a button and did nothing when tapped.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.activeTintColor = UIColor(named: "AccentColor") ?? .systemOrange
        view.tintColor = .secondaryLabel
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
