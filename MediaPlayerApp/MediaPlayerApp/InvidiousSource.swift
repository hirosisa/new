import Foundation

/// Optional YouTube fallback via **your own** Invidious instance.
///
/// `YouTubeSource` is the primary path and needs no server, so this exists only
/// as a backup for when on-device extraction breaks and you happen to self-host.
///
/// Deliberately disabled until you enter a host in Settings. As of this build,
/// every public instance either disables `/api/v1` outright, returns 401/403, or
/// serves an anti-bot interstitial instead of JSON — and every public Piped
/// instance fails too. See FINDINGS.md for the measurements. Shipping a bundled
/// instance list would guarantee an app that looks like it works and never plays
/// anything.
///
/// If you self-host (https://docs.invidious.io/installation/), this source
/// works, and the bugs that made the original implementation fail even against a
/// healthy instance are fixed here:
///
///  * `local=true` so media is proxied by your instance. Raw `googlevideo` URLs
///    are tied to the requesting IP and 403 from the phone.
///  * Audio track matching on `type.hasPrefix("audio/")`. The API returns full
///    MIME types (`audio/mp4; codecs="mp4a.40.2"`), so the old `type == "audio"`
///    check never matched and audio-only mode silently fell back to video.
///  * Corrected operator precedence in quality selection. `a && b || c` was
///    parsed as `(a && b) || c`, matching non-MP4 formats.
///  * Fully optional decoding, so one missing field doesn't fail the response.
///
/// Note that extracting YouTube streams is contrary to YouTube's Terms of
/// Service. That's your call to make; the app doesn't do it unless you configure it.
struct InvidiousSource: MediaSource {

    let id = "invidious"
    let displayName = "YouTube (self-hosted)"
    let systemImage = "network"
    let blurb = "Requires your own Invidious server. Public instances no longer serve their API."

    private let client = HTTPClient.shared

    /// Comma- or newline-separated hosts, tried in order.
    static let hostDefaultsKey = "invidiousHosts"

    static var hosts: [String] {
        get {
            let raw = UserDefaults.standard.string(forKey: hostDefaultsKey) ?? ""
            return raw
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(normalise)
        }
        set {
            UserDefaults.standard.set(newValue.joined(separator: ","), forKey: hostDefaultsKey)
        }
    }

    static func normalise(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespaces)
        if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var isAvailable: Bool { !Self.hosts.isEmpty }

    // MARK: - Search

    func search(query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = Self.hosts

        guard !trimmed.isEmpty else { return [] }
        guard !hosts.isEmpty else {
            throw SourceError.notConfigured("Add your Invidious host in Settings to enable YouTube.")
        }

        var lastError: Error = SourceError.notConfigured("No Invidious host responded.")

        // Iterative failover. The original recursed into itself through a
        // helper that also mutated a shared index, so the termination check was
        // unreliable and could recurse without bound.
        for host in hosts {
            do {
                guard var components = URLComponents(string: "\(host)/api/v1/search") else { continue }
                components.queryItems = [
                    URLQueryItem(name: "q", value: trimmed),
                    URLQueryItem(name: "type", value: "video"),
                    URLQueryItem(name: "sort_by", value: "relevance")
                ]
                guard let url = components.url else { continue }

                let rows = try await client.json([SearchRow].self, from: url)
                return rows.compactMap { row in
                    guard let videoID = row.videoId else { return nil }
                    return MediaItem(
                        sourceID: id,
                        nativeID: videoID,
                        title: row.title ?? "Untitled",
                        author: row.author ?? "YouTube",
                        artworkURL: row.thumbnailURL(host: host)
                            ?? URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg"),
                        duration: TimeInterval(row.lengthSeconds ?? 0),
                        kind: .video,
                        streamURL: nil,
                        detail: row.author
                    )
                }
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    // MARK: - Stream resolution

    func resolveStream(for item: MediaItem, preferAudioOnly: Bool) async throws -> URL {
        let hosts = Self.hosts
        guard !hosts.isEmpty else {
            throw SourceError.notConfigured("Add your Invidious host in Settings to enable YouTube.")
        }

        var lastError: Error = SourceError.noStream(item.title)

        for host in hosts {
            do {
                guard var components = URLComponents(string: "\(host)/api/v1/videos/\(item.nativeID)") else { continue }
                // `local=true` routes media through your instance, which is what
                // makes the resulting URL playable from the device at all.
                components.queryItems = [URLQueryItem(name: "local", value: "true")]
                guard let url = components.url else { continue }

                let video = try await client.json(VideoDetail.self, from: url)

                if let chosen = video.bestStream(preferAudioOnly: preferAudioOnly),
                   let streamURL = Self.absolute(chosen, host: host) {
                    return streamURL
                }
                lastError = SourceError.noStream(item.title)
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    /// `local=true` yields instance-relative paths like `/latest_version?...`.
    private static func absolute(_ path: String, host: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        if path.hasPrefix("/") {
            return URL(string: host + path)
        }
        return URL(string: "\(host)/\(path)")
    }
}

// MARK: - Payloads (every field optional by design)

private struct SearchRow: Decodable {
    let videoId: String?
    let title: String?
    let author: String?
    let lengthSeconds: Int?
    let videoThumbnails: [Thumb]?

    struct Thumb: Decodable {
        let quality: String?
        let url: String?
    }

    func thumbnailURL(host: String) -> URL? {
        let thumbs = videoThumbnails ?? []
        let preferred = thumbs.first { $0.quality == "high" }
            ?? thumbs.first { $0.quality == "medium" }
            ?? thumbs.first

        guard let raw = preferred?.url else { return nil }
        if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
        if raw.hasPrefix("/") { return URL(string: host + raw) }
        return URL(string: raw)
    }
}

private struct VideoDetail: Decodable {
    let formatStreams: [Format]?
    let adaptiveFormats: [Format]?
    let hlsUrl: String?

    struct Format: Decodable {
        let url: String?
        let type: String?
        let quality: String?
        /// Invidious has returned this as both a JSON string and a number
        /// across versions, so it decodes through a tolerant wrapper.
        let bitrate: FlexibleNumber?
        let container: String?

        var isAudio: Bool { type?.hasPrefix("audio/") ?? false }
        var isVideo: Bool { type?.hasPrefix("video/") ?? false }

        /// AVPlayer can't play WebM/Opus; restrict to MP4-family containers.
        var isAVPlayerCompatible: Bool {
            let mime = type?.lowercased() ?? ""
            if mime.contains("webm") || mime.contains("opus") || mime.contains("vorbis") {
                return false
            }
            guard let container = container?.lowercased() else { return true }
            return ["mp4", "m4a", "m4v", "mov"].contains(container)
        }

        var bitrateValue: Int { bitrate?.intValue ?? 0 }

        /// Muxed streams report `quality` as `hd720`/`medium`; rank numerically.
        var heightScore: Int {
            let q = quality?.lowercased() ?? ""
            if q.contains("1080") { return 1080 }
            if q.contains("720") { return 720 }
            if q.contains("480") { return 480 }
            if q.contains("360") { return 360 }
            if q.contains("hd") { return 720 }
            if q.contains("medium") { return 360 }
            return 0
        }
    }

    func bestStream(preferAudioOnly: Bool) -> String? {
        if preferAudioOnly {
            // Highest-bitrate compatible audio track.
            let audio = (adaptiveFormats ?? [])
                .filter { $0.isAudio && $0.isAVPlayerCompatible && $0.url != nil }
                .max { $0.bitrateValue < $1.bitrateValue }
            if let url = audio?.url { return url }
        }

        // Muxed video+audio. Note the parentheses: the original expression was
        // `container == "mp4" && quality.contains("720") || quality.contains("1080")`,
        // which `&&`-before-`||` precedence turned into something quite different.
        let muxed = (formatStreams ?? [])
            .filter { ($0.container?.lowercased() == "mp4" || $0.isAVPlayerCompatible) && $0.url != nil }
            .max { $0.heightScore < $1.heightScore }
        if let url = muxed?.url { return url }

        // Livestreams only.
        if let hls = hlsUrl, !hls.isEmpty { return hls }

        // Last resort: any compatible audio track, even if video was requested.
        return (adaptiveFormats ?? [])
            .filter { $0.isAudio && $0.isAVPlayerCompatible && $0.url != nil }
            .max { $0.bitrateValue < $1.bitrateValue }?
            .url
    }
}

/// Decodes a JSON value that may be a number or a numeric string.
struct FlexibleNumber: Decodable, Sendable {
    let intValue: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            intValue = int
        } else if let double = try? container.decode(Double.self) {
            intValue = Int(double)
        } else if let string = try? container.decode(String.self) {
            intValue = Int(string)
        } else {
            intValue = nil
        }
    }
}
