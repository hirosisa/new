import Foundation

/// A content backend.
///
/// The original app hard-wired a single provider into the UI, so when that
/// provider stopped serving its API the whole app became useless. Sources are
/// now interchangeable: add one, and Browse/Settings pick it up automatically.
protocol MediaSource: Sendable {
    /// Stable identifier, embedded in every `MediaItem.id`.
    var id: String { get }
    var displayName: String { get }
    var systemImage: String { get }
    /// A one-line explanation shown in Settings.
    var blurb: String { get }
    /// `false` when the user hasn't supplied required configuration yet.
    var isAvailable: Bool { get }

    func search(query: String) async throws -> [MediaItem]

    /// Returns a directly playable URL. Sources whose search results already
    /// carry `streamURL` can use the default implementation.
    func resolveStream(for item: MediaItem, preferAudioOnly: Bool) async throws -> URL
}

extension MediaSource {
    var isAvailable: Bool { true }

    func resolveStream(for item: MediaItem, preferAudioOnly: Bool) async throws -> URL {
        guard let url = item.streamURL else {
            throw SourceError.noStream(item.title)
        }
        return url
    }
}

// MARK: - Registry

/// Owns the concrete sources and fans a query out across all of them.
@MainActor
final class SourceRegistry: ObservableObject {

    static let shared = SourceRegistry()

    let youtube = YouTubeSource()
    let podcasts = PodcastSource()
    let archive = ArchiveSource()
    let local = LocalFilesSource()
    let invidious = InvidiousSource()

    /// Sources the user has switched off, persisted across launches.
    @AppStorageBacked("disabledSourceIDs") private var disabledIDs: Set<String>

    private init() {}

    /// Order matters: this is the order shown in Settings, and the order used
    /// when interleaving search results. YouTube is first because it's the
    /// primary source.
    var all: [MediaSource] {
        [youtube, podcasts, archive, local, invidious]
    }

    var enabled: [MediaSource] {
        all.filter { $0.isAvailable && !disabledIDs.contains($0.id) }
    }

    func isEnabled(_ source: MediaSource) -> Bool {
        !disabledIDs.contains(source.id)
    }

    func setEnabled(_ enabled: Bool, for source: MediaSource) {
        if enabled {
            disabledIDs.remove(source.id)
        } else {
            disabledIDs.insert(source.id)
        }
        objectWillChange.send()
    }

    func source(withID id: String) -> MediaSource? {
        all.first { $0.id == id }
    }

    func source(for item: MediaItem) -> MediaSource? {
        source(withID: item.sourceID)
    }

    /// Searches every enabled source concurrently and interleaves the results
    /// so no single backend dominates the list. Failures are collected rather
    /// than thrown, so one dead source can't blank the screen.
    func searchAll(query: String) async -> (items: [MediaItem], failures: [String]) {
        let targets = enabled
        guard !targets.isEmpty else { return ([], ["No sources are enabled."]) }

        var perSource: [[MediaItem]] = Array(repeating: [], count: targets.count)
        var failures: [String] = []

        // The child task result carries a pre-rendered failure string rather
        // than an `Error`. `Error` is not `Sendable`, so passing one across a
        // task group boundary is a concurrency warning today and an error under
        // strict checking.
        await withTaskGroup(of: (index: Int, items: [MediaItem], failure: String?).self) { group in
            for (index, source) in targets.enumerated() {
                let name = source.displayName
                group.addTask {
                    do {
                        let items = try await source.search(query: query)
                        return (index, items, nil)
                    } catch is CancellationError {
                        return (index, [], nil)
                    } catch {
                        if let sourceError = error as? SourceError, sourceError == .cancelled {
                            return (index, [], nil)
                        }
                        let reason = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        return (index, [], "\(name): \(reason)")
                    }
                }
            }

            for await result in group {
                perSource[result.index] = result.items
                if let failure = result.failure {
                    failures.append(failure)
                }
            }
        }

        // The primary source leads. Everything else is interleaved after it, so
        // secondary sources are still reachable without burying YouTube.
        let primaryIndex = targets.firstIndex { $0.id == Self.primarySourceID }

        var ordered: [MediaItem] = []
        if let primaryIndex {
            ordered = perSource[primaryIndex]
            perSource[primaryIndex] = []
        }
        ordered.append(contentsOf: Self.interleave(perSource))

        var seen = Set<String>()
        let deduped = ordered.filter { seen.insert($0.id).inserted }

        return (deduped, failures)
    }

    /// Results from this source are placed ahead of all others.
    static let primarySourceID = "youtube"

    /// Round-robin merge, preserving each source's own ranking.
    static func interleave(_ groups: [[MediaItem]]) -> [MediaItem] {
        let maxCount = groups.map(\.count).max() ?? 0
        var merged: [MediaItem] = []
        var seen = Set<String>()

        for offset in 0..<maxCount {
            for group in groups where offset < group.count {
                let item = group[offset]
                if seen.insert(item.id).inserted {
                    merged.append(item)
                }
            }
        }
        return merged
    }
}

// MARK: - Small persisted-value helper

/// `@AppStorage` doesn't handle `Set<String>`, and a property wrapper keeps the
/// call sites tidy. Values are stored as a JSON blob in `UserDefaults`.
@propertyWrapper
struct AppStorageBacked<Value: Codable> {
    private let key: String
    private let defaultValue: Value

    init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Value {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(Value.self, from: data)
            else { return defaultValue }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}

extension AppStorageBacked where Value == Set<String> {
    init(_ key: String) {
        self.init(key, default: [])
    }
}
