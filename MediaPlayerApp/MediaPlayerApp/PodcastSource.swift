import Foundation

/// Podcasts via Apple's public iTunes Search API plus standard RSS feeds.
///
/// No API key, no rate-limit signup, no ads injected by us, and the enclosure
/// URLs are plain `audio/mpeg` (or mp4) with `Accept-Ranges: bytes`, so AVPlayer
/// can stream and seek them natively.
///
/// Two-pass search: episode search is fast but Apple returns few rows, so when
/// it comes back thin we also search shows and pull recent episodes from the
/// top feeds concurrently.
struct PodcastSource: MediaSource {

    let id = "podcast"
    let displayName = "Podcasts"
    let systemImage = "mic.fill"
    let blurb = "Apple's public podcast directory. Millions of shows, direct RSS audio, no key required."

    private let client = HTTPClient.shared
    private let episodeTarget = 12
    private let maxFeedsToExpand = 3

    func search(query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results = try await searchEpisodes(trimmed)

        if results.count < episodeTarget {
            let feeds = try await searchShowFeeds(trimmed, limit: maxFeedsToExpand)
            let expanded = await expand(feeds: feeds)
            var seen = Set(results.map(\.id))
            for item in expanded where seen.insert(item.id).inserted {
                results.append(item)
            }
        }

        return results
    }

    // MARK: - Episode search

    private func searchEpisodes(_ query: String) async throws -> [MediaItem] {
        guard let url = URL.itunesSearch(term: query, entity: "podcastEpisode", limit: 25) else {
            return []
        }
        let response = try await client.json(ITunesResponse.self, from: url)
        return response.results.compactMap(Self.item(fromEpisode:))
    }

    private static func item(fromEpisode row: ITunesResponse.Row) -> MediaItem? {
        guard let urlString = row.episodeUrl, let stream = URL(string: urlString) else { return nil }
        let title = row.trackName ?? "Untitled episode"
        let show = row.collectionName ?? "Podcast"

        return MediaItem(
            sourceID: "podcast",
            nativeID: row.trackId.map(String.init) ?? stream.absoluteString,
            title: title,
            author: show,
            artworkURL: row.artworkURL,
            duration: row.durationSeconds,
            kind: row.isVideo ? .video : .audio,
            streamURL: stream,
            detail: show
        )
    }

    // MARK: - Show search -> feed expansion

    private func searchShowFeeds(_ query: String, limit: Int) async throws -> [URL] {
        guard let url = URL.itunesSearch(term: query, entity: "podcast", limit: limit) else {
            return []
        }
        let response = try await client.json(ITunesResponse.self, from: url)
        return response.results.compactMap { row in
            row.feedUrl.flatMap(URL.init(string:))
        }
    }

    private func expand(feeds: [URL]) async -> [MediaItem] {
        guard !feeds.isEmpty else { return [] }

        var collected: [[MediaItem]] = Array(repeating: [], count: feeds.count)

        await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, feed) in feeds.enumerated() {
                group.addTask {
                    do {
                        let data = try await client.data(from: feed, accept: "application/rss+xml, application/xml, text/xml")
                        let parsed = RSSParser.parse(data: data, limit: 6)
                        return (index, parsed)
                    } catch {
                        return (index, [])
                    }
                }
            }
            for await (index, items) in group {
                collected[index] = items
            }
        }

        return SourceRegistry.interleave(collected)
    }
}

// MARK: - iTunes Search API payload

/// Every field is optional. Apple varies the shape by `entity`, and a single
/// unexpected null previously failed the whole decode.
private struct ITunesResponse: Decodable {
    let results: [Row]

    struct Row: Decodable {
        let trackId: Int?
        let trackName: String?
        let collectionName: String?
        let feedUrl: String?
        let episodeUrl: String?
        let trackTimeMillis: Double?
        let artworkUrl600: String?
        let artworkUrl100: String?
        let episodeContentType: String?

        var durationSeconds: TimeInterval {
            guard let ms = trackTimeMillis, ms.isFinite, ms > 0 else { return 0 }
            return ms / 1000
        }

        var artworkURL: URL? {
            if let s = artworkUrl600, let u = URL(string: s) { return u }
            if let s = artworkUrl100, let u = URL(string: s) { return u }
            return nil
        }

        var isVideo: Bool {
            episodeContentType?.lowercased().hasPrefix("video") ?? false
        }
    }
}

private extension URL {
    static func itunesSearch(term: String, entity: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return components?.url
    }
}

// MARK: - Minimal RSS reader

/// Pulls `<item>` entries with a playable `<enclosure>` out of a podcast feed.
/// `XMLParser` is used rather than a regex so CDATA and entities behave.
private final class RSSParser: NSObject, XMLParserDelegate {

    static func parse(data: Data, limit: Int) -> [MediaItem] {
        let parser = RSSParser(limit: limit)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        xml.parse()
        return parser.items
    }

    private let limit: Int
    private var items: [MediaItem] = []

    private var channelTitle = ""
    private var channelImage: URL?

    private var insideItem = false
    private var currentElement = ""
    private var text = ""

    private var itemTitle = ""
    private var itemDuration: TimeInterval = 0
    private var itemGUID = ""
    private var itemImage: URL?
    private var enclosureURL: URL?
    private var enclosureIsVideo = false

    private init(limit: Int) {
        self.limit = limit
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {

        currentElement = elementName
        text = ""

        switch elementName {
        case "item":
            insideItem = true
            itemTitle = ""
            itemDuration = 0
            itemGUID = ""
            itemImage = nil
            enclosureURL = nil
            enclosureIsVideo = false

        case "enclosure":
            let type = (attributeDict["type"] ?? "").lowercased()
            guard type.hasPrefix("audio") || type.hasPrefix("video"),
                  let urlString = attributeDict["url"],
                  let url = URL(string: urlString) else { return }
            enclosureURL = url
            enclosureIsVideo = type.hasPrefix("video")

        case "itunes:image":
            if let href = attributeDict["href"], let url = URL(string: href) {
                if insideItem { itemImage = url } else { channelImage = url }
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            text += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title":
            if insideItem { itemTitle = value } else if channelTitle.isEmpty { channelTitle = value }

        case "itunes:duration":
            itemDuration = Self.seconds(fromDurationString: value)

        case "guid":
            if insideItem { itemGUID = value }

        case "item":
            insideItem = false
            defer { text = "" }

            guard items.count < limit,
                  let stream = enclosureURL,
                  !itemTitle.isEmpty else { return }

            let native = itemGUID.isEmpty ? stream.absoluteString : itemGUID
            items.append(
                MediaItem(
                    sourceID: "podcast",
                    nativeID: native,
                    title: itemTitle,
                    author: channelTitle.isEmpty ? "Podcast" : channelTitle,
                    artworkURL: itemImage ?? channelImage,
                    duration: itemDuration,
                    kind: enclosureIsVideo ? .video : .audio,
                    streamURL: stream,
                    detail: channelTitle
                )
            )

            if items.count >= limit {
                parser.abortParsing()
            }

        default:
            break
        }

        text = ""
    }

    /// Handles `1:02:33`, `4:07`, and bare seconds — all three appear in the wild.
    private static func seconds(fromDurationString raw: String) -> TimeInterval {
        guard !raw.isEmpty else { return 0 }

        let parts = raw.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }
}
