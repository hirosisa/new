import SwiftUI
import UniformTypeIdentifiers

/// Favourites, recently played, and the on-device file library.
struct LibraryView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var registry: SourceRegistry

    @State private var shelf: Shelf = .favorites
    @State private var localItems: [MediaItem] = []
    @State private var showImporter = false
    @State private var importError: String?

    /// Named `Shelf` rather than `Section` so it can't be confused with
    /// `SwiftUI.Section` inside this file's view builders.
    enum Shelf: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case recents = "Recent"
        case files = "Files"

        var id: String { rawValue }
    }

    private var items: [MediaItem] {
        switch shelf {
        case .favorites: return library.favorites
        case .recents: return library.recents
        case .files: return localItems
        }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Section {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    itemRows
                } footer: {
                    if shelf == .files {
                        Text("Files live in the app's Documents folder. Add them here, by AirDrop, or with Finder file sharing.")
                    }
                }
            }
        }
        .navigationTitle("Library")
        // Inline: the large title is scroll content and rubber-bands down
        // with a pull-to-refresh, which read as the header moving.
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Shelf", selection: $shelf) {
                ForEach(Shelf.allCases) { shelf in
                    Text(shelf.rawValue).tag(shelf)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert("Import failed", isPresented: importErrorBinding) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .task(id: shelf) {
            if shelf == .files { refreshLocalItems() }
        }
        .refreshable {
            if shelf == .files { refreshLocalItems() }
        }
    }

    // MARK: - Rows

    /// Delete and move are only wired up for the shelves that support them.
    /// Passing a ternary of optional closures into `onDelete`/`onMove` is
    /// fragile to type-check, so each case is spelled out.
    @ViewBuilder
    private var itemRows: some View {
        switch shelf {
        case .favorites:
            ForEach(items) { item in row(for: item) }
                .onDelete { offsets in library.removeFavorites(atOffsets: offsets) }
                .onMove { source, destination in
                    library.moveFavorites(from: source, to: destination)
                }

        case .files:
            ForEach(items) { item in row(for: item) }
                .onDelete { offsets in deleteFiles(at: offsets) }

        case .recents:
            ForEach(items) { item in row(for: item) }
        }
    }

    private func row(for item: MediaItem) -> some View {
        LibraryRow(item: item) {
            engine.play(item: item, in: items)
            library.notePlayed(item)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if shelf == .files {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Import files")
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if !items.isEmpty {
                Menu {
                    Button("Play all", systemImage: "play.fill") {
                        guard let first = items.first else { return }
                        engine.play(item: first, in: items)
                    }

                    Button("Shuffle all", systemImage: "shuffle") {
                        guard let first = items.shuffled().first else { return }
                        engine.play(item: first, in: items)
                        if !engine.isShuffled { engine.toggleShuffle() }
                    }

                    Button("Add all to queue", systemImage: "text.append") {
                        engine.addToQueue(items)
                    }

                    Divider()

                    // Explicit label form: the argument order of the
                    // title/systemImage/role convenience initialiser varies
                    // between SDK versions, and this spelling is stable.
                    if shelf == .favorites {
                        Button(role: .destructive) {
                            library.removeAllFavorites()
                        } label: {
                            Label("Remove all favorites", systemImage: "trash")
                        }
                    } else if shelf == .recents {
                        Button(role: .destructive) {
                            library.clearRecents()
                        } label: {
                            Label("Clear history", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                if shelf != .recents {
                    EditButton()
                }
            }
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        switch shelf {
        case .favorites:
            ContentUnavailableView(
                "No favorites",
                systemImage: "heart",
                description: Text("Swipe right on anything in Browse to save it here.")
            )

        case .recents:
            ContentUnavailableView(
                "Nothing played yet",
                systemImage: "clock",
                description: Text("Your listening history will show up here.")
            )

        case .files:
            ContentUnavailableView {
                Label("No files yet", systemImage: "folder")
            } description: {
                Text("Import audio or video from the Files app. These play offline and never expire.")
            } actions: {
                Button("Import files") { showImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    private func deleteFiles(at offsets: IndexSet) {
        let doomed = offsets.compactMap { localItems.indices.contains($0) ? localItems[$0] : nil }
        for item in doomed {
            try? LocalFilesSource.delete(item)
        }
        localItems.remove(atOffsets: offsets)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            var failures: [String] = []
            for url in urls {
                do {
                    try LocalFilesSource.importFile(at: url)
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            if !failures.isEmpty {
                importError = "Couldn't import: \(failures.joined(separator: ", "))"
            }
            refreshLocalItems()

        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    private func refreshLocalItems() {
        localItems = registry.local.allItems()
    }
}

// MARK: - Row

private struct LibraryRow: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    let item: MediaItem
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: item.artworkURL, fallbackSystemImage: item.kind.systemImage)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(item.detail ?? item.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if engine.currentItem?.id == item.id {
                Image(systemName: engine.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            } else if item.duration > 0 {
                Text(item.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                engine.addToQueue([item])
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.accentColor)
        }
    }
}
