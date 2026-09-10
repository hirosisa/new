import Foundation
import SwiftUI

/// Favourites and recently-played, persisted as JSON in Application Support.
///
/// Two changes from the original:
///
///  * **File-backed rather than `UserDefaults`.** `UserDefaults` is loaded into
///    memory on every launch and isn't intended for a list that grows without
///    bound.
///  * **Mutation is only possible through this type.** Views previously reached
///    in and mutated the `@Published` array directly, then called a `private`
///    save method — which didn't compile, and would have silently dropped writes
///    if it had.
@MainActor
final class Library: ObservableObject {

    @Published private(set) var favorites: [MediaItem] = []
    @Published private(set) var recents: [MediaItem] = []

    private let maxRecents = 50
    private let fileURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: support.path) {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }
        self.fileURL = support.appendingPathComponent("library.json")
        load()
    }

    // MARK: - Favourites

    func isFavorite(_ item: MediaItem) -> Bool {
        favorites.contains { $0.id == item.id }
    }

    func toggleFavorite(_ item: MediaItem) {
        if let index = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(item, at: 0)
        }
        save()
    }

    func removeFavorites(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        favorites.removeAll { ids.contains($0.id) }
        save()
    }

    func removeFavorites(atOffsets offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        save()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func removeAllFavorites() {
        favorites.removeAll()
        save()
    }

    // MARK: - Recents

    func notePlayed(_ item: MediaItem) {
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        if recents.count > maxRecents {
            recents.removeLast(recents.count - maxRecents)
        }
        save()
    }

    func clearRecents() {
        recents.removeAll()
        save()
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var favorites: [MediaItem]
        var recents: [MediaItem]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // A schema change shouldn't wedge the app; start clean instead.
            return
        }
        favorites = payload.favorites
        recents = payload.recents
    }

    private func save() {
        let payload = Payload(favorites: favorites, recents: recents)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Offline downloads

/// Streams downloaded for offline playback. Files land in
/// `Documents/Downloads` as `<item.id>.m4a` (audio) or `.mp4` (muxed video,
/// which carries audio too). Playback resolves the local file before any
/// network source, so a downloaded item plays offline and never expires.
@MainActor
final class DownloadManager: ObservableObject {

    static let shared = DownloadManager()

    @Published private(set) var activeIDs: Set<String> = []

    private let directory: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        FileManager.default.fileExists(atPath: audioFileURL(for: item).path)
            || FileManager.default.fileExists(atPath: videoFileURL(for: item).path)
    }

    func isDownloading(_ item: MediaItem) -> Bool { activeIDs.contains(item.id) }

    func audioFileURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent("\(item.id).m4a")
    }

    func videoFileURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent("\(item.id).mp4")
    }

    /// Local file for playback, preferred by current mode, falling back to the
    /// other format if that's what was downloaded.
    func localFile(for item: MediaItem, audioOnly: Bool) -> URL? {
        let preferred = audioOnly ? audioFileURL(for: item) : videoFileURL(for: item)
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let fallback = audioOnly ? videoFileURL(for: item) : audioFileURL(for: item)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    func delete(_ item: MediaItem) {
        for url in [audioFileURL(for: item), videoFileURL(for: item)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Resolves a single-file progressive stream and downloads it. Audio takes
    /// the best m4a; video takes the muxed mp4 — the HLS rewrites are local
    /// playlist files, not downloadable single streams.
    func download(_ item: MediaItem, registry: SourceRegistry, audioOnly: Bool) {
        guard !isDownloaded(item), !activeIDs.contains(item.id) else { return }
        activeIDs.insert(item.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { activeIDs.remove(item.id) }
            do {
                let source = registry.source(for: item)
                guard let youtube = source as? YouTubeSource else { return }
                let remote = try await youtube.downloadableStream(
                    for: item,
                    preferAudioOnly: audioOnly
                )
                let destination = audioOnly ? audioFileURL(for: item) : videoFileURL(for: item)
                let (temp, response) = try await URLSession.shared.download(from: remote)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw SourceError.http(
                        status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                        host: remote.host ?? "googlevideo"
                    )
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                // The button returns to its download state; nothing partial
                // is left behind, so the user can simply retry.
            }
        }
    }
}
