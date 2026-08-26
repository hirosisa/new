import SwiftUI

/// Search across every enabled source at once.
struct BrowseView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var registry: SourceRegistry

    @StateObject private var model = BrowseModel()
    @State private var kindFilter: KindFilter = .all

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case audio = "Audio"
        case video = "Video"

        var id: String { rawValue }
    }

    private var visibleResults: [MediaItem] {
        switch kindFilter {
        case .all: return model.results
        case .audio: return model.results.filter { $0.kind == .audio }
        case .video: return model.results.filter { $0.kind == .video }
        }
    }

    var body: some View {
        List {
            if !model.failures.isEmpty {
                Section {
                    ForEach(model.failures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Some sources didn't respond")
                }
            }

            if visibleResults.isEmpty {
                Section {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(visibleResults) { item in
                        ResultRow(item: item) {
                            engine.play(item: item, in: visibleResults)
                            library.notePlayed(item)
                        }
                    }
                } header: {
                    Text("\(visibleResults.count) result\(visibleResults.count == 1 ? "" : "s")")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Browse")
        .searchable(text: $model.query, prompt: "Podcasts, audiobooks, music, film")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Type", selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .overlay {
            if model.isSearching && model.results.isEmpty {
                ProgressView("Searching…")
            }
        }
        // Debounced: the previous version only searched on submit and had no
        // cancellation, so overlapping requests could resolve out of order.
        .task(id: model.query) {
            await model.runSearch(registry: registry)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView {
                Label("Search your sources", systemImage: "magnifyingglass")
            } description: {
                Text("Podcasts, Internet Archive audio and video, and files on this iPhone.")
            }
        } else if model.isSearching {
            EmptyView()
        } else {
            ContentUnavailableView.search(text: model.query)
        }
    }
}

// MARK: - Row

private struct ResultRow: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    let item: MediaItem
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: item.artworkURL, fallbackSystemImage: item.kind.systemImage)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                Text(item.detail ?? item.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(item.kind == .video ? "Video" : "Audio", systemImage: item.kind.systemImage)
                    if item.duration > 0 {
                        Text(item.formattedDuration)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if engine.currentItem?.id == item.id {
                Image(systemName: engine.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .foregroundStyle(.tint)
                    .font(.footnote)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                library.toggleFavorite(item)
            } label: {
                Label(library.isFavorite(item) ? "Unfavorite" : "Favorite",
                      systemImage: library.isFavorite(item) ? "heart.slash" : "heart")
            }
            .tint(.pink)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                engine.addToQueue([item])
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button("Play now", systemImage: "play.fill", action: onPlay)
            Button("Add to queue", systemImage: "text.append") {
                engine.addToQueue([item])
            }
            Button {
                library.toggleFavorite(item)
            } label: {
                if library.isFavorite(item) {
                    Label("Remove from favorites", systemImage: "heart.slash")
                } else {
                    Label("Add to favorites", systemImage: "heart")
                }
            }
        }
    }
}

// MARK: - Model

@MainActor
final class BrowseModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [MediaItem] = []
    @Published private(set) var failures: [String] = []
    @Published private(set) var isSearching = false

    /// Called from `.task(id:)`, so SwiftUI cancels the previous run whenever
    /// the query changes. The debounce lives here rather than in a manual
    /// `Task` so cancellation and lifetime are handled for us.
    func runSearch(registry: SourceRegistry) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            results = []
            failures = []
            isSearching = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return // Superseded by a newer keystroke.
        }

        isSearching = true
        let outcome = await registry.searchAll(query: trimmed)

        guard !Task.isCancelled else { return }
        results = outcome.items
        failures = outcome.failures
        isSearching = false
    }
}
