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
    @State private var isSelecting = false
    @State private var selected: Set<String> = []
    @State private var showDeleteConfirmation = false

    /// Named `Shelf` rather than `Section` so it can't be confused with
    /// `SwiftUI.Section` inside this file's view builders.
    enum Shelf: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case recents = "Recent"
        case downloads = "Downloads"
        case files = "Files"

        var id: String { rawValue }
    }

    @ObservedObject private var downloads = DownloadManager.shared

    private var items: [MediaItem] {
        switch shelf {
        case .favorites: return library.favorites
        case .recents: return library.recents
        case .downloads: return downloads.allDownloads()
        case .files: return localItems
        }
    }

    private var selectedItems: [MediaItem] {
        items.filter { selected.contains($0.id) }
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
        .onChange(of: shelf) {
            isSelecting = false
            selected.removeAll()
        }
        .refreshable {
            if shelf == .files { refreshLocalItems() }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete (\(selected.count))", systemImage: "trash")
                    }
                    .disabled(selected.isEmpty)

                    Spacer()

                    Button {
                        engine.addToQueue(selectedItems)
                        isSelecting = false
                        selected.removeAll()
                    } label: {
                        Label("Add to queue", systemImage: "text.append")
                    }
                    .disabled(selected.isEmpty)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .confirmationDialog(
            "Delete \(selectedItems.count) selected item\(selectedItems.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteSelected()
            }
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

        case .downloads:
            ForEach(items) { item in row(for: item) }
                .onDelete { offsets in
                    for index in offsets { downloads.delete(items[index]) }
                }

        case .recents:
            ForEach(items) { item in row(for: item) }
        }
    }

    private func row(for item: MediaItem) -> some View {
        LibraryRow(
            item: item,
            isSelecting: isSelecting,
            isSelected: selected.contains(item.id)
        ) {
            engine.play(item: item, in: items)
            library.notePlayed(item)
        } onToggleSelect: {
            if selected.contains(item.id) {
                selected.remove(item.id)
                if selected.isEmpty { isSelecting = false }
            } else {
                selected.insert(item.id)
            }
        } onDelete: {
            deleteOne(item)
        }
    }

    /// Per-shelf single-item delete for the swipe action.
    private func deleteOne(_ item: MediaItem) {
        switch shelf {
        case .favorites:
            library.removeFavorites(ids: [item.id])
        case .recents:
            library.removeRecents(ids: [item.id])
        case .downloads:
            downloads.delete(item)
        case .files:
            try? LocalFilesSource.delete(item)
            refreshLocalItems()
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
            if isSelecting {
                Button("Done") {
                    isSelecting = false
                    selected.removeAll()
                }
            } else if !items.isEmpty {
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

                    Button("Select multiple", systemImage: "checkmark.circle") {
                        isSelecting = true
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

        case .downloads:
            ContentUnavailableView(
                "No downloads",
                systemImage: "arrow.down.circle",
                description: Text("Downloaded songs show up here and play offline.")
            )
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

    /// Per-shelf delete for the multi-select action bar.
    private func deleteSelected() {
        let doomed = selectedItems
        switch shelf {
        case .favorites:
            library.removeFavorites(ids: Set(doomed.map(\.id)))
        case .recents:
            library.removeRecents(ids: Set(doomed.map(\.id)))
        case .downloads:
            doomed.forEach { downloads.delete($0) }
        case .files:
            doomed.forEach { try? LocalFilesSource.delete($0) }
            refreshLocalItems()
        }
        selected.removeAll()
        if items.isEmpty { isSelecting = false }
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
    var isSelecting: Bool = false
    var isSelected: Bool = false
    let onPlay: () -> Void
    var onToggleSelect: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }

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

            if !isSelecting {
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
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                onToggleSelect?()
            } else {
                onPlay()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button {
                engine.addToQueue([item])
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.accentColor)
        }
    }
}
