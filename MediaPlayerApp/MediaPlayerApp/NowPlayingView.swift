import SwiftUI
import AVKit

/// One player screen for both audio and video.
///
/// The original split this into a Video tab and a Music tab that duplicated the
/// controls and disagreed with each other — the audio/video toggle used inverted
/// icons in the two screens, and the loop button in one of them could not cycle
/// out of shuffle. A single screen that adapts to `item.kind` removes that class
/// of bug.
struct NowPlayingView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    @StateObject private var pip = PiPCoordinator()
    @State private var showQueue = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let sleepMinutes = [5, 10, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                if let item = engine.currentItem {
                    content(for: item)
                } else {
                    ContentUnavailableView(
                        "Nothing playing",
                        systemImage: "music.note",
                        description: Text("Pick something from Browse or Library.")
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.headline)
                    }
                    .accessibilityLabel("Close player")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showQueue = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Show queue")
                }
            }
            .sheet(isPresented: $showQueue) {
                QueueView()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                stage(for: item)

                titleBlock(for: item)

                if let error = engine.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                scrubber

                transportRow

                secondaryRow(for: item)

                Spacer(minLength: 24)
            }
            .padding(.top, 8)
        }
    }

    /// Video renders in an `AVPlayerLayer`; audio shows artwork.
    @ViewBuilder
    private func stage(for item: MediaItem) -> some View {
        if engine.hasVideo {
            VideoSurface(player: engine.player) { controller in
                pip.adopt(controller)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .overlay {
                if engine.isLoading {
                    ProgressView().tint(.white)
                }
            }
        } else {
            Artwork(url: item.artworkURL, fallbackSystemImage: item.kind.systemImage)
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 18, y: 10)
                .overlay {
                    if engine.isLoading {
                        ProgressView()
                    }
                }
        }
    }

    private func titleBlock(for item: MediaItem) -> some View {
        VStack(spacing: 6) {
            Text(item.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Text(item.detail ?? item.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : engine.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(engine.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = engine.currentTime
                        scrubbing = true
                    } else {
                        engine.seek(to: scrubValue)
                        scrubbing = false
                    }
                }
            )
            .disabled(engine.duration <= 0)

            HStack {
                Text(Formatters.duration(scrubbing ? scrubValue : engine.currentTime))
                Spacer()
                Text(Formatters.duration(engine.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 28) {
            Button {
                engine.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(engine.isShuffled ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel(engine.isShuffled ? "Shuffle on" : "Shuffle off")

            Button {
                engine.previous()
            } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            .disabled(!engine.canGoPrevious)

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

            Button {
                engine.next()
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .disabled(!engine.canGoNext)

            Button {
                engine.cycleRepeatMode()
            } label: {
                Image(systemName: engine.repeatMode.systemImage)
                    .font(.title3)
                    .foregroundStyle(engine.repeatMode == .off ? Color.secondary : Color.accentColor)
            }
            .accessibilityLabel(engine.repeatMode.label)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    // MARK: - Secondary controls

    private func secondaryRow(for item: MediaItem) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 26) {
                Button {
                    engine.skipBackward(15)
                } label: {
                    Image(systemName: "gobackward.15")
                }

                Button {
                    engine.skipForward(30)
                } label: {
                    Image(systemName: "goforward.30")
                }

                Button {
                    library.toggleFavorite(item)
                } label: {
                    Image(systemName: library.isFavorite(item) ? "heart.fill" : "heart")
                        .foregroundStyle(library.isFavorite(item) ? Color.pink : Color.primary)
                }
                .accessibilityLabel(library.isFavorite(item) ? "Remove from favorites" : "Add to favorites")

                // Only meaningful for video, and it says what it does rather
                // than showing the opposite icon in different screens.
                if item.kind == .video {
                    Button {
                        engine.setAudioOnly(!engine.audioOnly)
                    } label: {
                        Image(systemName: engine.audioOnly ? "music.note" : "film")
                            .foregroundStyle(engine.audioOnly ? Color.accentColor : Color.primary)
                    }
                    .accessibilityLabel(engine.audioOnly ? "Audio only. Switch to video" : "Video. Switch to audio only")
                }

                if engine.hasVideo && pip.isSupported {
                    Button {
                        pip.toggle()
                    } label: {
                        Image(systemName: "pip.enter")
                    }
                    .accessibilityLabel("Picture in Picture")
                }
            }
            .font(.title3)
            .buttonStyle(.plain)

            HStack(spacing: 20) {
                Menu {
                    ForEach(speeds, id: \.self) { speed in
                        Button {
                            engine.setPlaybackSpeed(speed)
                        } label: {
                            if engine.playbackSpeed == speed {
                                Label(Formatters.speedLabel(speed), systemImage: "checkmark")
                            } else {
                                Text(Formatters.speedLabel(speed))
                            }
                        }
                    }
                } label: {
                    Label(Formatters.speedLabel(engine.playbackSpeed), systemImage: "speedometer")
                        .font(.footnote)
                }

                Menu {
                    if engine.sleepTimerRemaining != nil {
                        Button("Cancel timer", systemImage: "xmark") {
                            engine.cancelSleepTimer()
                        }
                        Divider()
                    }
                    ForEach(sleepMinutes, id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            engine.startSleepTimer(minutes: minutes)
                        }
                    }
                } label: {
                    Label(
                        engine.sleepTimerRemaining.map { Formatters.duration($0) } ?? "Sleep",
                        systemImage: "moon.zzz"
                    )
                    .font(.footnote)
                }

                AirPlayButton()
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("AirPlay")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}
