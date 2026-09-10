import SwiftUI

struct RootView: View {
    @State private var selectedTab = Tab.browse
    @State private var showNowPlaying = false

    enum Tab: Hashable {
        case browse, library
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                BrowseView()
            }
            .miniPlayerInset(isPresented: $showNowPlaying)
            .tabItem { Label("Browse", systemImage: "magnifyingglass") }
            .tag(Tab.browse)

            NavigationStack {
                LibraryView()
            }
            .miniPlayerInset(isPresented: $showNowPlaying)
            .tabItem { Label("Library", systemImage: "heart.fill") }
            .tag(Tab.library)
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}

// MARK: - Mini player placement

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var engine: PlayerEngine
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        // `safeAreaInset` is what keeps the bar above the tab bar and also
        // insets the scroll content so the last row isn't hidden behind it.
        // The original overlaid the mini player on the TabView itself, which
        // covered the tab bar and clipped list content.
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if engine.currentItem != nil {
                MiniPlayerView(onTap: { isPresented = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: engine.currentItem?.id)
    }
}

extension View {
    func miniPlayerInset(isPresented: Binding<Bool>) -> some View {
        modifier(MiniPlayerInset(isPresented: isPresented))
    }
}

// MARK: - Mini player

struct MiniPlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine

    let onTap: () -> Void

    var body: some View {
        // `currentItem` is read once into a local. The original force-unwrapped
        // `currentItem!` inside the body, which crashes if the item clears
        // between the visibility check and the body evaluation.
        if let item = engine.currentItem {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Artwork(url: item.artworkURL, fallbackSystemImage: item.kind.systemImage)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(item.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if engine.isLoading {
                        ProgressView().controlSize(.small)
                    }

                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        engine.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.subheadline)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.canGoNext)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ProgressView(value: engine.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now playing: \(item.title) by \(item.author)")
            .accessibilityHint("Double tap to open the full player")
        }
    }
}

// MARK: - Shared artwork view

/// Async artwork with a graceful placeholder. Local files have no artwork URL,
/// so the fallback glyph matters.
struct Artwork: View {
    let url: URL?
    var fallbackSystemImage: String = "music.note"

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            placeholder
                        case .empty:
                            ProgressView().controlSize(.small)
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
    }

    private var placeholder: some View {
        Image(systemName: fallbackSystemImage)
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}
