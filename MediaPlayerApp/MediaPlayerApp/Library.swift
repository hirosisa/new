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
