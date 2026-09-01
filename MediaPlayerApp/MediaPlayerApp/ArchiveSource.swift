import Foundation

/// Internet Archive — audio and video from a public, open catalogue.
///
/// Verified working: `advancedsearch.php` for discovery, `/metadata/{id}` for the
/// file list, and `/download/{id}/{file}` serves `audio/mpeg` (or mp4) with
/// `Accept-Ranges: bytes`. Millions of items: LibriVox audiobooks, live concert
/// recordings, public-domain film, radio archives.
///
/// Stream URLs need a second round trip (search returns items, not files), so
/// `resolveStream` does the metadata lookup lazily at play time.
struct ArchiveSource: MediaSource {

    let id = "archive"
    let displayName = "Internet Archive"
    let systemImage = "building.columns.fill"
    let blurb = "Public-domain and freely-licensed audio and video. No key, no ads, no bot checks."

    private let client = HTTPClient.shared
    private let rows = 15

    /// AVPlayer handles these reliably. Ogg/FLAC/opus are skipped on purpose.
    private static let playableExtensions = ["mp3", "m4a", "mp4", "m4v", "aac", "mov"]
    private static let videoExtensions = ["mp4", "m4v", "mov"]

    // MARK: - Search

    func search(query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let url = searchURL(for: trimmed) else { return [] }
        let response = try await client.json(SearchResponse.self, from: url)

        return response.response.docs.compactMap { doc in
            guard let identifier = doc.identifier else { return nil }
            let isVideo = (doc.mediatype ?? "") == "movies"

            return MediaItem(
                sourceID: id,
                nativeID: identifier,
                title: doc.bestTitle,
                author: doc.bestCreator,
                artworkURL: URL(string: "https://archive.org/services/img/\(identifier)"),
                duration: 0, // Unknown until the file list is fetched.
                kind: isVideo ? .video : .audio,
                streamURL: nil,
                detail: doc.year.map { "Internet Archive · \($0)" } ?? "Internet Archive"
            )
        }
    }

    private func searchURL(for query: String) -> URL? {
        // Restrict to formats AVPlayer can actually play, so results aren't
        // dominated by items that turn out to be FLAC-only or text.
        let escaped = query.replacingOccurrences(of: "\"", with: " ")
        let lucene = """
        (title:("\(escaped)") OR creator:("\(escaped)") OR subject:("\(escaped)")) \
        AND (mediatype:"audio" OR mediatype:"movies") \
        AND (format:"MP3" OR format:"MPEG4")
        """

        var components = URLComponents(string: "https://archive.org/advancedsearch.php")
        components?.queryItems = [
            URLQueryItem(name: "q", value: lucene),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "mediatype"),
            URLQueryItem(name: "fl[]", value: "year"),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "output", value: "json")
        ]
        return components?.url
    }

    // MARK: - Stream resolution

    func resolveStream(for item: MediaItem, preferAudioOnly: Bool) async throws -> URL {
        if let known = item.streamURL { return known }

        guard let url = URL(string: "https://archive.org/metadata/\(item.nativeID)") else {
            throw SourceError.noStream(item.title)
        }

        let metadata = try await client.json(Metadata.self, from: url)
        let files = metadata.files ?? []

        let wantVideo = item.kind == .video && !preferAudioOnly
        let candidates = files.filter { file in
            guard let name = file.name?.lowercased() else { return false }
            let ext = (name as NSString).pathExtension
            guard Self.playableExtensions.contains(ext) else { return false }
            return wantVideo ? Self.videoExtensions.contains(ext)
                             : !Self.videoExtensions.contains(ext)
        }

        // Audio-only playback of a video item: fall back to any playable file.
        let pool = candidates.isEmpty
            ? files.filter { file in
                guard let name = file.name?.lowercased() else { return false }
                return Self.playableExtensions.contains((name as NSString).pathExtension)
              }
            : candidates

        // Prefer the longest file, which for a multi-file item is the feature
        // rather than a trailer or a per-chapter snippet.
        guard let chosen = pool.max(by: { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }),
              let name = chosen.name,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .archivePathAllowed),
              let streamURL = URL(string: "https://archive.org/download/\(item.nativeID)/\(encoded)")
        else {
            throw SourceError.noStream(item.title)
        }

        return streamURL
    }
}

// MARK: - Payloads

private struct SearchResponse: Decodable {
    let response: Inner

    struct Inner: Decodable {
        let docs: [Doc]
    }

    struct Doc: Decodable {
        let identifier: String?
        let mediatype: String?
        let year: FlexibleString?
        // `title` and `creator` are sometimes a string, sometimes an array.
        let title: FlexibleString?
        let creator: FlexibleString?

        var bestTitle: String { title?.value ?? identifier ?? "Untitled" }
        var bestCreator: String { creator?.value ?? "Internet Archive" }
    }
}

private struct Metadata: Decodable {
    let files: [File]?

    struct File: Decodable {
        let name: String?
        let size: String?

        var sizeBytes: Int64? { size.flatMap(Int64.init) }
    }
}

/// Archive.org returns some metadata fields as either a bare string or an array
/// of strings depending on the item. Decoding both shapes avoids losing results.
private struct FlexibleString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            value = single
        } else if let many = try? container.decode([String].self) {
            value = many.first
        } else if let num = try? container.decode(Int.self) {
            value = String(num)  // archive returns `year` as a bare integer sometimes
        } else if let num = try? container.decode(Double.self) {
            value = String(num)
        } else {
            value = nil
        }
    }
}

private extension CharacterSet {
    /// Archive filenames contain spaces, brackets and ampersands.
    static let archivePathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")
        return set
    }()
}
