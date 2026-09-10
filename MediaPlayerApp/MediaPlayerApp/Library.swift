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

/// Streams saved for offline playback, downloaded through the HLS endpoint
/// (master → media playlist → segments concatenated). The progressive
/// endpoint that single-file downloads would use fails outright on some
/// networks (measured on-device: NSURLErrorDomain -1), while HLS keeps
/// serving. Audio segments are ID3+ADTS AAC → saved as `.aac`; video
/// segments are muxed MPEG-TS → saved as `.ts`. AVPlayer plays both.
@MainActor
final class DownloadManager: ObservableObject {

    static let shared = DownloadManager()

    @Published private(set) var activeIDs: Set<String> = []
    @Published private(set) var fractions: [String: Double] = [:]
    /// Surfaced by the UI so a failed download is never silent.
    @Published var lastError: String?

    private let directory: URL
    private let manifestURL: URL
    private var manifest: [String: StoredDownload] = [:]

    /// What the Library shelf needs to list a download as a row.
    private struct StoredDownload: Codable {
        let sourceID: String
        let nativeID: String
        let title: String
        let author: String
        let artworkURL: URL?
        let duration: TimeInterval
        let kind: MediaItem.Kind
        let ext: String
    }

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manifestURL = directory.appendingPathComponent("manifest.json")
        loadManifest()
    }

    func isDownloading(_ item: MediaItem) -> Bool { activeIDs.contains(item.id) }
    func fraction(for item: MediaItem) -> Double? { fractions[item.id] }

    /// The downloaded file for an item, or nil. The extension is sniffed at
    /// save time (.aac / .ts), so the lookup scans for the id prefix.
    func localFile(for item: MediaItem, audioOnly: Bool) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = files.first(where: { $0.hasPrefix("\(item.id).") }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// All downloads as listable rows for the Library shelf.
    func allDownloads() -> [MediaItem] {
        manifest.values.map { stored in
            MediaItem(
                sourceID: stored.sourceID,
                nativeID: stored.nativeID,
                title: stored.title,
                author: stored.author,
                artworkURL: stored.artworkURL,
                duration: stored.duration,
                kind: stored.kind
            )
        }
        .sorted { $0.title < $1.title }
    }

    func delete(_ item: MediaItem) {
        if let file = localFile(for: item, audioOnly: true) {
            try? FileManager.default.removeItem(at: file)
        }
        manifest.removeValue(forKey: item.id)
        saveManifest()
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        manifest[item.id] != nil
            && FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(item.id).\(manifest[item.id]!.ext)").path)
    }

    /// Resolves the HLS master, picks a playlist (best audio rendition, or the
    /// highest H.264 variant — the master lists variants lowest-first), then
    /// downloads every segment and concatenates them into one file.
    /// `masterHint` short-circuits resolution when the item is currently
    /// playing and the engine already holds a working master URL.
    func download(
        _ item: MediaItem,
        registry: SourceRegistry,
        audioOnly: Bool,
        masterHint: URL? = nil
    ) {
        guard manifest[item.id] == nil, !activeIDs.contains(item.id) else { return }
        activeIDs.insert(item.id)
        fractions[item.id] = 0

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                activeIDs.remove(item.id)
                fractions[item.id] = nil
            }
            do {
                // Tier 1 (audio only): the engine's already-attached master.
                // Tier 2 (audio only): an HLS master's audio rendition.
                // Tier 3: muxed single file (itag 18 — video with audio).
                //
                // Video downloads go straight to the muxed tier: measured via
                // ffprobe, YouTube's video-variant TS segments carry NO audio
                // stream (it lives in the separate rendition groups), and
                // there is no remuxer on device — an HLS-tier video download
                // would be silent.
                var hlsReasons: String?
                var hintReasons: String?
                var singleFileReasons: String?
                var result: (data: Data, ext: String)?

                // The static fetchers run on the class's @MainActor isolation,
                // so progress writes are synchronous — no fire-and-forget Task
                // that could land after the defer cleanup.
                func segmentsProgress(_ fraction: Double) {
                    self?.fractions[item.id] = fraction
                }
                func fileProgress(_ fraction: Double) {
                    self?.fractions[item.id] = fraction
                }

                let youtube = registry.source(for: item) as? YouTubeSource
                if audioOnly, let hint = masterHint,
                   hint.isFileURL || hint.pathExtension.lowercased() == "m3u8" {
                    do {
                        result = try await Self.fetchSegments(
                            master: hint,
                            audioOnly: true,
                            onProgress: segmentsProgress
                        )
                    } catch {
                        hintReasons = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
                if audioOnly, result == nil, let youtube {
                    do {
                        let master = try await youtube.hlsMasterURL(for: item)
                        result = try await Self.fetchSegments(
                            master: master,
                            audioOnly: true,
                            onProgress: segmentsProgress
                        )
                    } catch {
                        hlsReasons = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
                if result == nil, let youtube {
                    do {
                        let remote = try await youtube.singleFileStream(for: item)
                        result = try await Self.fetchWholeFile(
                            remote,
                            audioOnly: audioOnly,
                            onProgress: fileProgress
                        )
                    } catch {
                        singleFileReasons = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
                if let youtube, audioOnly, result == nil {
                    // One more try for audio: the muxed tier above already ran;
                    // a progressive-audio-only URL is the last resort.
                    do {
                        if let remote = try await youtube.progressiveAudioStream(for: item) {
                            result = try await Self.fetchWholeFile(
                                remote,
                                audioOnly: true,
                                onProgress: fileProgress
                            )
                        }
                    } catch {
                        singleFileReasons = (singleFileReasons.map { $0 + " | " } ?? "")
                            + ((error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription)
                    }
                }
                if result == nil, youtube == nil {
                    throw SourceError.notConfigured("Downloads are YouTube-only.")
                }

                guard let (data, ext) = result else {
                    throw SourceError.notConfigured(
                        [hintReasons, hlsReasons, singleFileReasons].compactMap { $0 }
                            .joined(separator: " | ")
                    )
                }

                let file = directory.appendingPathComponent("\(item.id).\(ext)")
                try data.write(to: file, options: .atomic)
                manifest[item.id] = StoredDownload(
                    sourceID: item.sourceID,
                    nativeID: item.nativeID,
                    title: item.title,
                    author: item.author,
                    artworkURL: item.artworkURL,
                    duration: item.duration,
                    kind: item.kind,
                    ext: ext
                )
                saveManifest()
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Fetches the master, picks a playlist, and concatenates every segment.
    /// Measured live: audio segments are ID3+ADTS AAC; video variant segments
    /// are muxed MPEG-TS (188-byte packets) — both concatenate into a file
    /// AVPlayer plays directly.
    private static func fetchSegments(
        master: URL,
        audioOnly: Bool,
        onProgress: @escaping (Double) -> Void
    ) async throws -> (Data, String) {
        let coreMedia = "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)"

        func attribute(_ line: String, _ name: String) -> String? {
            guard let range = line.range(of: "\(name)=\"") else { return nil }
            let tail = line[range.upperBound...]
            return tail.firstIndex(of: "\"").map { String(tail[..<$0]) }
        }

        func fetchText(_ url: URL) async throws -> String {
            var request = URLRequest(url: url)
            request.setValue(coreMedia, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(data: data, encoding: .utf8) ?? ""
        }

        func pickPlaylist(from masterText: String) -> String? {
            let lines = masterText.split(separator: "\n").map(String.init)
            if audioOnly {
                if let line = lines.first(where: {
                    $0.hasPrefix("#EXT-X-MEDIA:") && attribute($0, "TYPE") == "AUDIO"
                }) {
                    return attribute(line, "URI")
                }
                return nil
            }
            // Video: the highest-resolution H.264 variant. The master lists
            // variants lowest-resolution first, so scan for the max height.
            var best: (height: Int, uri: String)?
            var index = 0
            while index < lines.count - 1 {
                if lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
                    let uri = lines[index + 1]
                    if uri.hasPrefix("http"),
                       attribute(lines[index], "CODECS")?.contains("avc1") == true {
                        let height = attribute(lines[index], "RESOLUTION")?
                            .split(separator: "x").last.flatMap { Int($0) } ?? 0
                        if height > (best?.height ?? 0) { best = (height, uri) }
                    }
                    index += 2
                    continue
                }
                index += 1
            }
            return best?.uri
        }

        let masterText = try await fetchText(master)
        guard let playlistText = pickPlaylist(from: masterText),
              let playlistURL = URL(string: playlistText) else {
            throw SourceError.noStream("No downloadable playlist in the HLS master.")
        }
        let mediaPlaylist = try await fetchText(playlistURL)
        let segments = mediaPlaylist.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("http") }
        guard !segments.isEmpty else {
            throw SourceError.noStream("No segments in the media playlist.")
        }

        var data = Data()
        for (offset, segmentText) in segments.enumerated() {
            guard let url = URL(string: segmentText) else { continue }
            var request = URLRequest(url: url)
            request.setValue(coreMedia, forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw SourceError.http(
                    status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    host: url.host ?? "googlevideo"
                )
            }
            for try await byte in bytes { data.append(byte) }
            onProgress(Double(offset + 1) / Double(segments.count))
        }
        return (data, sniffExtension(of: data))
    }

    /// Last tier: download a single progressive file (muxed itag 18 or
    /// progressive audio) in **1 MB ranged chunks** — the exact request shape
    /// AVPlayer itself uses, and the only one this network reliably serves
    /// (whole-file GETs die with URLError.timedOut / -1). Each chunk retries
    /// once, so one flaky range doesn't kill the download.
    private static func fetchWholeFile(
        _ remote: URL,
        audioOnly: Bool,
        onProgress: @escaping (Double) -> Void
    ) async throws -> (Data, String) {
        let coreMedia = "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)"
        let chunkSize = 1_048_576

        func rangedRequest(_ range: ClosedRange<Int>?) -> URLRequest {
            var request = URLRequest(url: remote)
            request.timeoutInterval = 30
            request.setValue(coreMedia, forHTTPHeaderField: "User-Agent")
            if let range {
                request.setValue(
                    "bytes=\(range.lowerBound)-\(range.upperBound)",
                    forHTTPHeaderField: "Range"
                )
            }
            return request
        }

        // Probe the total size with a 1-byte range; googlevideo answers
        // "bytes 0-0/TOTAL". A non-206 means ranges aren't honored — fall
        // back to one plain stream.
        var probe = URLRequest(url: remote, timeoutInterval: 30)
        probe.setValue(coreMedia, forHTTPHeaderField: "User-Agent")
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, probeResponse) = try await URLSession.shared.bytes(for: probe)
        guard let probeHTTP = probeResponse as? HTTPURLResponse else {
            throw SourceError.transport("Download probe returned no HTTP response.")
        }
        let total = probeHTTP.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last.flatMap { Int($0) } ?? -1
        guard probeHTTP.statusCode == 206, total > 0 else {
            var request = rangedRequest(nil)
            request.timeoutInterval = 60
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw SourceError.http(
                    status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    host: remote.host ?? "googlevideo"
                )
            }
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return (data, Self.sniffMediaExtension(data, audioOnly: audioOnly))
        }

        var data = Data(capacity: total)
        var start = 0
        while start < total {
            let end = min(start + chunkSize, total) - 1
            let expected = end - start + 1
            var chunk: Data?
            for _ in 0..<2 { // one retry per chunk
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(
                        for: rangedRequest(start...end)
                    )
                    // A ranged request MUST answer 206: a 200 means the Range
                    // header was ignored and the full body would be appended
                    // at a non-zero offset — silent corruption.
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 206 else {
                        throw SourceError.http(
                            status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                            host: remote.host ?? "googlevideo"
                        )
                    }
                    var received = Data()
                    for try await byte in bytes { received.append(byte) }
                    // Short reads must not advance past unread bytes.
                    guard received.count == expected else {
                        throw SourceError.transport(
                            "Chunk \(start)-\(end) delivered \(received.count)/\(expected) bytes."
                        )
                    }
                    chunk = received
                    break
                } catch {
                    chunk = nil
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            guard let received = chunk else {
                throw SourceError.transport(
                    "Chunk \(start)-\(end) failed after retry."
                )
            }
            data.append(received)
            start = end + 1
            onProgress(min(0.99, Double(start) / Double(total)))
        }
        return (data, Self.sniffMediaExtension(data, audioOnly: audioOnly))
    }

    private static func sniffMediaExtension(_ data: Data, audioOnly: Bool) -> String {
        let head = [UInt8](data.prefix(4))
        if head.elementsEqual(Array("ftyp".utf8)) {
            return audioOnly ? "m4a" : "mp4"
        }
        if head.first == 0x47 { return "ts" }
        if head.starts(with: [0x49, 0x44, 0x33])
            || head.starts(with: [0xFF, 0xF1])
            || head.starts(with: [0xFF, 0xF9]) {
            return "aac"
        }
        return audioOnly ? "m4a" : "ts"
    }

    /// Container sniffing: MPEG-TS → .ts, ID3/ADTS AAC → .aac, fMP4 → .mp4.
    private static func sniffExtension(of data: Data) -> String {
        let head = [UInt8](data.prefix(4))
        if head.first == 0x47 { return "ts" }
        if head.starts(with: [0x49, 0x44, 0x33]) { return "aac" }
        if head.starts(with: [0xFF, 0xF1]) || head.starts(with: [0xFF, 0xF9]) { return "aac" }
        if head.elementsEqual(Array("ftyp".utf8)) { return "mp4" }
        return "ts"
    }

    // MARK: Manifest persistence

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? JSONDecoder().decode([String: StoredDownload].self, from: data)
        else { return }
        manifest = stored
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: [.atomic])
    }
}
