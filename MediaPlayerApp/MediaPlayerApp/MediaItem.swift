import Foundation

/// A single playable thing: a podcast episode, an Internet Archive track,
/// a local file, or (if you self-host Invidious) a YouTube video.
///
/// `streamURL` is populated eagerly by sources that already know the direct
/// media URL. Sources that need a second network round trip leave it `nil`,
/// and `MediaSource.resolveStream(for:preferAudioOnly:)` fills it in at play time.
struct MediaItem: Identifiable, Codable, Hashable, Sendable {

    enum Kind: String, Codable, Sendable {
        case audio
        case video

        var systemImage: String {
            switch self {
            case .audio: return "music.note"
            case .video: return "play.rectangle"
            }
        }
    }

    /// Globally unique and stable: `"<sourceID>:<nativeID>"`.
    let id: String
    /// Identifier of the `MediaSource` that produced this item.
    let sourceID: String
    /// The source's own identifier, used when resolving a stream.
    let nativeID: String
    let title: String
    let author: String
    let artworkURL: URL?
    /// Seconds. `0` means unknown — resolved from the player once loaded.
    let duration: TimeInterval
    let kind: Kind
    /// Direct media URL when the source already knows it.
    let streamURL: URL?
    /// Freeform subtitle, e.g. show name or collection.
    let detail: String?

    init(
        sourceID: String,
        nativeID: String,
        title: String,
        author: String,
        artworkURL: URL? = nil,
        duration: TimeInterval = 0,
        kind: Kind = .audio,
        streamURL: URL? = nil,
        detail: String? = nil
    ) {
        self.id = "\(sourceID):\(nativeID)"
        self.sourceID = sourceID
        self.nativeID = nativeID
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.duration = duration
        self.kind = kind
        self.streamURL = streamURL
        self.detail = detail
    }

    /// Returns a copy carrying a freshly resolved stream URL.
    func withStreamURL(_ url: URL) -> MediaItem {
        MediaItem(
            sourceID: sourceID,
            nativeID: nativeID,
            title: title,
            author: author,
            artworkURL: artworkURL,
            duration: duration,
            kind: kind,
            streamURL: url,
            detail: detail
        )
    }

    var formattedDuration: String { Formatters.duration(duration) }
}

// MARK: - Playback modes

/// Repeat behaviour. Kept separate from shuffle so the two are independently
/// toggleable — the previous single-enum design made "shuffle" a dead end that
/// no button could cycle out of.
enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one

    var systemImage: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}
