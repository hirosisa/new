import Foundation

/// YouTube, extracted on-device. No server, no API key, no third-party instance.
///
/// ## How it works
///
/// YouTube's own apps talk to an internal JSON API ("InnerTube") at
/// `/youtubei/v1/*`. This source speaks the same protocol. Which *client identity*
/// you claim changes what you're allowed to fetch, so the app keeps a ranked list
/// of identities and walks it until one works.
///
/// Measured against the live API, three clients independently return playable
/// streams and three do not:
///
/// | Client | playabilityStatus | Audio | Muxed | HLS | Cipher | Fetch |
/// |---|---|---|---|---|---|---|
/// | `IOS` | OK | 2 | 0 | **yes** | none | 206 |
/// | `ANDROID_VR` | OK | 2 | 1 | no | none | 206 |
/// | `ANDROID` | OK | 3 | 1 | no | none | 206 |
/// | `WEB` | UNPLAYABLE | — | — | — | — | — |
/// | `MWEB` / `TVHTML5` | UNPLAYABLE | — | — | — | — | — |
/// | `IOS_MUSIC` | LOGIN_REQUIRED | — | — | — | — | — |
///
/// Two properties make this workable without a server:
///
///  * **No signature cipher.** Every returned format carries a plain `url`, so
///    there's no need to download and interpret YouTube's player JavaScript —
///    the fragile, heavyweight part of every other extractor.
///  * **No PO Token.** `WEB` is refused outright without BotGuard attestation;
///    these clients are not.
///
/// `IOS` is ranked first because it's the only one exposing `hlsManifestUrl`,
/// which `AVPlayer` plays natively with adaptive bitrate up to 3840x2160. The
/// Android clients are the safety net and additionally provide muxed progressive
/// formats, which `IOS` does not.
///
/// A further useful property: googlevideo URLs are IP-bound. Extracting *on the
/// device* binds them to the device's own IP — which is exactly why proxy-based
/// designs 403 from the phone and this doesn't.
///
/// ## Why there are no ads
///
/// Nothing is blocked, which is what makes it durable — there's no filter list to
/// keep current. Ads are injected by YouTube's *player* as separate playback
/// requests, described by `adPlacements` in the player response. The content
/// stream carries no advertising, so requesting the media URL directly means an
/// ad is never part of the pipeline. Verified: `adPlacements` empty, and no
/// `EXT-X-DATERANGE` / `EXT-X-CUE-OUT` / `SCTE35` / `EXT-X-SPLICEPOINT` markers
/// in either the HLS master or the media playlist.
///
/// Progressive `adaptiveFormats` URLs cannot carry inserted ads at all, so
/// audio-only mode is structurally immune. `preferProgressiveVideo` in Settings
/// extends that guarantee to video, trading resolution for it.
///
/// ## Two caveats worth being clear about
///
/// 1. **This is contrary to YouTube's Terms of Service.** Your device, a personal
///    non-distributed build — but the app isn't pretending otherwise.
/// 2. **It needs occasional maintenance.** YouTube rotates accepted client
///    versions. The fallback chain means one client tightening is survivable
///    rather than fatal, but eventually the version strings in
///    `MAINTENANCE: client identities` below need bumping. Run
///    `scripts/probe-clients.py` to see which identities currently work and
///    `scripts/probe-youtube.py` to see which pipeline stage broke.
struct YouTubeSource: MediaSource {

    let id = "youtube"
    let displayName = "YouTube"
    let systemImage = "play.rectangle.fill"
    let blurb = "Direct on-device extraction with a 3-client fallback chain. Ad-free because ads are never requested."

    private let client = HTTPClient.shared

    // MARK: - Client identity

    /// One InnerTube client identity.
    struct ClientProfile: Sendable {
        let id: String
        let name: String
        let version: String
        let userAgent: String
        var deviceMake: String?
        var deviceModel: String?
        var osName: String?
        var osVersion: String?
        var androidSdkVersion: Int?
        /// Only `IOS` currently exposes `hlsManifestUrl`.
        var providesHLS: Bool = false

        init(id: String,
             name: String,
             version: String,
             userAgent: String,
             deviceMake: String? = nil,
             deviceModel: String? = nil,
             osName: String? = nil,
             osVersion: String? = nil,
             androidSdkVersion: Int? = nil,
             providesHLS: Bool = false) {
            self.id = id
            self.name = name
            self.version = version
            self.userAgent = userAgent
            self.deviceMake = deviceMake
            self.deviceModel = deviceModel
            self.osName = osName
            self.osVersion = osVersion
            self.androidSdkVersion = androidSdkVersion
            self.providesHLS = providesHLS
        }
    }

    // ========================================================================
    // MAINTENANCE: client identities
    //
    // These version strings are the only values that routinely go stale. When
    // playback stops working, run scripts/probe-clients.py, then update whatever
    // it reports as broken. Cross-check current values against yt-dlp, which
    // tracks the same clients.
    // ========================================================================

    private static let chromeUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

    /// Builds an `IOS` profile for a specific app version. Several versions are
    /// kept in the chain because **newer is not better**: measured 2026-08-26,
    /// the then-current App Store release (21.34.3) returned
    /// `playabilityStatus: OK` and a working HLS manifest but *zero* progressive
    /// audio formats — video played, audio-only mode silently died. 20.03.02
    /// through 21.10.1 each returned two. So the app pins verified-good versions
    /// and falls through them rather than tracking the latest release.
    ///
    /// `scripts/probe-versions.py` re-checks which versions are currently good.
    private static func iosProfile(version: String) -> ClientProfile {
        ClientProfile(
            id: "ios-\(version)",
            name: "IOS",
            version: version,
            userAgent: "com.google.ios.youtube/\(version) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)",
            deviceMake: "Apple",
            deviceModel: "iPhone16,2",
            osName: "iPhone",
            osVersion: "18.3.2.22D82",
            providesHLS: true
        )
    }

    /// Tried in order for stream resolution. Ranked by capability, then by how
    /// reliable each has proven.
    ///
    /// Note how the fallthrough interacts with audio-only: if a client returns no
    /// progressive audio, `selectPreferredStream` yields nil for an audio-only
    /// request and the chain simply moves on — so a version that loses audio
    /// support degrades into "skipped" rather than "broken".
    static let playerClients: [ClientProfile] = [
        iosProfile(version: "20.10.4"),
        iosProfile(version: "21.10.1"),
        iosProfile(version: "20.30.2"),
        ClientProfile(
            id: "android_vr",
            name: "ANDROID_VR",
            version: "1.62.27",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12; en_US)",
            deviceMake: "Oculus",
            deviceModel: "Quest 3",
            osName: "Android",
            osVersion: "12",
            androidSdkVersion: 32
        ),
        ClientProfile(
            id: "android",
            name: "ANDROID",
            version: "20.10.38",
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 15; en_US) gzip",
            deviceMake: "Google",
            deviceModel: "Pixel 9",
            osName: "Android",
            osVersion: "15",
            androidSdkVersion: 35
        ),
    ]

    /// Tried in order for search. `WEB` is preferred because it returns
    /// conventional `videoRenderer` objects; the `IOS` client serialises results
    /// into protobuf blobs that aren't practical to parse.
    static let searchClients: [ClientProfile] = [
        ClientProfile(
            id: "web",
            name: "WEB",
            version: "2.20250312.04.00",
            userAgent: chromeUserAgent
        ),
        ClientProfile(
            id: "android_vr",
            name: "ANDROID_VR",
            version: "1.62.27",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12; en_US)",
            deviceMake: "Oculus",
            deviceModel: "Quest 3",
            osName: "Android",
            osVersion: "12",
            androidSdkVersion: 32
        ),
    ]

    private static let endpoint = "https://www.youtube.com/youtubei/v1"

    /// Opaque InnerTube filter meaning "videos only". Verified against the live API.
    private static let videoOnlyParams = "EgIQAQ%3D%3D"

    // MARK: - Preferences

    /// When true, video uses a muxed progressive stream instead of HLS: lower
    /// resolution, but a format that structurally cannot contain inserted ads.
    static var preferProgressiveVideo: Bool {
        get { UserDefaults.standard.bool(forKey: "youtubePreferProgressive") }
        set { UserDefaults.standard.set(newValue, forKey: "youtubePreferProgressive") }
    }

    /// Remembers which client last succeeded so the chain starts with a known-good
    /// identity instead of re-failing through the same dead one every time.
    private static var lastGoodPlayerClientID: String? {
        get { UserDefaults.standard.string(forKey: "youtubeLastGoodClient") }
        set { UserDefaults.standard.set(newValue, forKey: "youtubeLastGoodClient") }
    }

    /// Video IDs whose HLS master stalled AVPlayer this session. The next resolve
    /// skips HLS and uses a muxed progressive stream instead.
    private static let hlsSkip = HLSSkipState()
    /// The rewritten master has to stay on disk for as long as AVPlayer is using it.
    private static var retainedHLSFile: URL?

    /// Called by the player when HLS never starts. Next resolve uses muxed MP4.
    static func disableHLS(for item: MediaItem) {
        hlsSkip.insert(item.nativeID)
    }

    /// The player chain, with the last known-good client moved to the front.
    private static func orderedPlayerClients() -> [ClientProfile] {
        guard let preferred = lastGoodPlayerClientID,
              let index = playerClients.firstIndex(where: { $0.id == preferred }),
              index != 0
        else { return playerClients }

        var ordered = playerClients
        let profile = ordered.remove(at: index)
        ordered.insert(profile, at: 0)
        return ordered
    }

    // MARK: - Search

    func search(query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let url = URL(string: "\(Self.endpoint)/search") else { return [] }

        var lastError: Error?

        for profile in Self.searchClients {
            do {
                let body = SearchRequest(
                    query: trimmed,
                    params: Self.videoOnlyParams,
                    context: .init(client: .init(profile: profile))
                )

                let data = try await client.postJSON(
                    url: url,
                    body: try JSONEncoder().encode(body),
                    userAgent: profile.userAgent
                )

                let items = Self.parseSearchResults(data: data, sourceID: id)
                if !items.isEmpty { return items }
                // Parsed fine but produced nothing usable: try the next client
                // before concluding the query genuinely has no results.
                lastError = SourceError.decoding("No parseable results from \(profile.name).")
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SourceError.decoding("YouTube returned no parseable results.")
    }

    /// The search response is deeply nested and its wrapper renderers change
    /// shape often, so it's walked as loose JSON looking for `videoRenderer` /
    /// `compactVideoRenderer` nodes. The *inside* of those nodes has been stable
    /// for years; the scaffolding around them has not.
    private static func parseSearchResults(data: Data, sourceID: String) -> [MediaItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var renderers: [[String: Any]] = []
        collect(node: root, keys: ["videoRenderer", "compactVideoRenderer"], into: &renderers)

        var seen = Set<String>()
        var results: [MediaItem] = []

        for renderer in renderers {
            guard let videoID = renderer["videoId"] as? String,
                  seen.insert(videoID).inserted else { continue }

            let title = text(in: renderer["title"]) ?? "Untitled"
            let author = text(in: renderer["ownerText"])
                ?? text(in: renderer["longBylineText"])
                ?? text(in: renderer["shortBylineText"])
                ?? "YouTube"

            // Absent for live streams.
            let lengthText = text(in: renderer["lengthText"])
            let duration = lengthText.map(parseDuration) ?? 0

            let views = text(in: renderer["viewCountText"])
            let detail = views.map { "\(author) · \($0)" }
                ?? (lengthText == nil ? "\(author) · Live" : author)

            results.append(
                MediaItem(
                    sourceID: sourceID,
                    nativeID: videoID,
                    title: title,
                    author: author,
                    // Built from the ID rather than parsed out: always present,
                    // always the right aspect, one less thing to break.
                    artworkURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg"),
                    duration: duration,
                    kind: .video,
                    streamURL: nil, // resolved lazily at play time
                    detail: detail
                )
            )
        }

        return results
    }

    // MARK: - Stream resolution

    func resolveStream(for item: MediaItem, preferAudioOnly: Bool) async throws -> URL {
        let allowHLSGlobally = !Self.preferProgressiveVideo
            && !Self.hlsSkip.contains(item.nativeID)

        var refusalReason: String?
        var lastError: Error?
        /// Something playable but not what was asked for, kept in case nothing
        /// better turns up across the whole chain.
        var compromise: URL?

        for profile in Self.orderedPlayerClients() {
            do {
                let response = try await playerResponse(videoID: item.nativeID, profile: profile)

                // A refusal is per-client: another identity may still be allowed,
                // so record the reason and keep going.
                if let reason = response.unplayableReason {
                    refusalReason = reason
                    continue
                }

                if let url = Self.selectPreferredStream(
                    from: response,
                    preferAudioOnly: preferAudioOnly,
                    allowHLS: allowHLSGlobally && profile.providesHLS
                ) {
                    Self.lastGoodPlayerClientID = profile.id
                    return await Self.playableURL(url)
                }

                if compromise == nil {
                    compromise = Self.selectAnyStream(from: response, allowHLS: allowHLSGlobally)
                }
            } catch {
                lastError = error
            }
        }

        if let compromise { return await Self.playableURL(compromise) }
        if let refusalReason { throw SourceError.notConfigured(refusalReason) }
        if let lastError { throw lastError }
        throw SourceError.noStream(item.title)
    }

    /// Exactly what was asked for, or nil so the chain tries another client.
    private static func selectPreferredStream(from response: PlayerResponse,
                                              preferAudioOnly: Bool,
                                              allowHLS: Bool) -> URL? {
        if preferAudioOnly {
            return response.bestProgressiveAudioURL
        }
        if allowHLS, let hls = response.hlsURL {
            return hls
        }
        return response.bestMuxedURL
    }

    /// Anything playable at all, as a last resort.
    private static func selectAnyStream(from response: PlayerResponse, allowHLS: Bool) -> URL? {
        if allowHLS, let hls = response.hlsURL { return hls }
        return response.bestMuxedURL ?? response.bestProgressiveAudioURL
    }

    /// HLS masters from the iOS client lead with VP9. AVPlayer often stalls on
    /// that; rewrite to H.264 variants when we can, otherwise pass the URL through.
    private static func playableURL(_ url: URL) async -> URL {
        guard looksLikeHLS(url), let rewritten = await avcOnlyMaster(from: url) else {
            return url
        }
        return rewritten
    }

    private static func looksLikeHLS(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.contains(".m3u8") || value.contains("manifest/hls")
    }

    /// Fetch the remote master and keep only `avc1` + AAC variants. Measured
    /// 2026-09-10: 10 VP9 renditions vs 7 H.264, so AVPlayer's first pick is VP9.
    private static func avcOnlyMaster(from remote: URL) async -> URL? {
        do {
            var request = URLRequest(url: remote)
            request.timeoutInterval = 20
            request.setValue(
                "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }

            let rewritten = filterMasterToAVC(text)
            guard rewritten.contains("#EXT-X-STREAM-INF") else { return nil }

            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let file = caches.appendingPathComponent("yt-hls-\(UUID().uuidString).m3u8")
            try rewritten.write(to: file, atomically: true, encoding: .utf8)
            if let previous = retainedHLSFile, previous != file {
                try? FileManager.default.removeItem(at: previous)
            }
            retainedHLSFile = file
            return file
        } catch {
            return nil
        }
    }

    /// Keep H.264 video + the AAC audio groups those variants reference.
    static func filterMasterToAVC(_ playlist: String) -> String {
        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)
        var keptAudioGroups = Set<String>()
        var keepStream = Array(repeating: false, count: lines.count)

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let codecs = attribute(named: "CODECS", in: line)?.lowercased() ?? ""
                let isAVC = codecs.contains("avc1") && !codecs.contains("vp09") && !codecs.contains("av01")
                keepStream[index] = isAVC
                if index + 1 < lines.count { keepStream[index + 1] = isAVC }
                if isAVC, let group = attribute(named: "AUDIO", in: line) {
                    keptAudioGroups.insert(group)
                }
                index += 2
                continue
            }
            index += 1
        }

        if keptAudioGroups.isEmpty && !keepStream.contains(true) {
            return playlist
        }

        var output: [String] = []
        index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                if keepStream[index] {
                    output.append(line)
                    if index + 1 < lines.count { output.append(lines[index + 1]) }
                }
                index += 2
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let type = attribute(named: "TYPE", in: line)
                if type == "AUDIO" {
                    if let group = attribute(named: "GROUP-ID", in: line), keptAudioGroups.contains(group) {
                        output.append(line)
                    }
                    index += 1
                    continue
                }
                // Drop captions / timed-text — they aren't needed for playback.
                if type == "SUBTITLES" {
                    index += 1
                    continue
                }
            }
            output.append(line)
            index += 1
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func attribute(named name: String, in line: String) -> String? {
        // AUDIO="234" or CODECS="avc1.4D401E,mp4a.40.2"
        let pattern = "\(name)="
        guard let range = line.range(of: pattern) else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            let inner = rest.dropFirst()
            guard let end = inner.firstIndex(of: "\"") else { return nil }
            return String(inner[..<end])
        }
        let end = rest.firstIndex(where: { $0 == "," || $0 == "\r" }) ?? rest.endIndex
        return String(rest[..<end])
    }

    private func playerResponse(videoID: String,
                                profile: ClientProfile) async throws -> PlayerResponse {
        guard let url = URL(string: "\(Self.endpoint)/player") else {
            throw SourceError.transport("Bad YouTube endpoint.")
        }

        let body = PlayerRequest(
            videoId: videoID,
            contentCheckOk: true,
            racyCheckOk: true,
            context: .init(client: .init(profile: profile))
        )

        let data = try await client.postJSON(
            url: url,
            body: try JSONEncoder().encode(body),
            userAgent: profile.userAgent
        )

        do {
            return try JSONDecoder().decode(PlayerResponse.self, from: data)
        } catch {
            throw SourceError.decoding(String(describing: error))
        }
    }

    // MARK: - Loose-JSON helpers

    private static func collect(node: Any, keys: [String], into out: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            for key in keys {
                if let match = dict[key] as? [String: Any] {
                    out.append(match)
                }
            }
            for value in dict.values {
                collect(node: value, keys: keys, into: &out)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collect(node: value, keys: keys, into: &out)
            }
        }
    }

    /// InnerTube text is either `{simpleText:}` or `{runs:[{text:}]}`.
    private static func text(in node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }

        if let simple = dict["simpleText"] as? String, !simple.isEmpty {
            return simple
        }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// `"6:10:58"`, `"2:50"`, `"58"`.
    private static func parseDuration(_ text: String) -> TimeInterval {
        let parts = text
            .split(separator: ":")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }
}

/// Session-scoped set of video IDs that stalled on HLS. Not an actor so the
/// player can mark a skip from the main actor without an isolation hop.
private final class HLSSkipState: @unchecked Sendable {
    private var ids = Set<String>()
    private let lock = NSLock()

    func insert(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}

// MARK: - Request bodies

private struct InnerTubeContext: Encodable {
    let client: InnerTubeClient
}

/// Optional fields are omitted rather than sent as null: Swift's synthesised
/// encoder uses `encodeIfPresent` for optionals, which is what lets one struct
/// describe both the Apple and Android client shapes.
private struct InnerTubeClient: Encodable {
    let clientName: String
    let clientVersion: String
    let deviceMake: String?
    let deviceModel: String?
    let osName: String?
    let osVersion: String?
    let androidSdkVersion: Int?
    let hl: String
    let gl: String

    init(profile: YouTubeSource.ClientProfile) {
        self.clientName = profile.name
        self.clientVersion = profile.version
        self.deviceMake = profile.deviceMake
        self.deviceModel = profile.deviceModel
        self.osName = profile.osName
        self.osVersion = profile.osVersion
        self.androidSdkVersion = profile.androidSdkVersion
        self.hl = "en"
        self.gl = "US"
    }
}

private struct SearchRequest: Encodable {
    let query: String
    let params: String
    let context: InnerTubeContext
}

private struct PlayerRequest: Encodable {
    let videoId: String
    let contentCheckOk: Bool
    let racyCheckOk: Bool
    let context: InnerTubeContext
}

// MARK: - Player response
//
// Unlike the search payload, this schema is stable and worth decoding strictly.

private struct PlayerResponse: Decodable {
    let playabilityStatus: Playability?
    let streamingData: StreamingData?
    let videoDetails: VideoDetails?

    struct Playability: Decodable {
        let status: String?
        let reason: String?
    }

    struct StreamingData: Decodable {
        let formats: [Format]?
        let adaptiveFormats: [Format]?
        let hlsManifestUrl: String?
    }

    struct Format: Decodable {
        let itag: Int?
        let url: String?
        let mimeType: String?
        let bitrate: Int?
        let height: Int?
        let qualityLabel: String?

        var mime: String { (mimeType ?? "").lowercased() }

        /// AVPlayer cannot decode WebM, Opus or Vorbis. Restrict to MP4-family.
        var isAVPlayerCompatible: Bool {
            !(mime.contains("webm") || mime.contains("opus") || mime.contains("vorbis"))
        }

        var isProgressiveAudio: Bool {
            mime.hasPrefix("audio/mp4") && url != nil
        }

        /// A muxed format carries both tracks, which is what makes it usable
        /// standalone — `adaptiveFormats` split video and audio into separate URLs
        /// that AVPlayer cannot recombine from two remote sources.
        ///
        /// Do not use `qualityLabel` as the muxed signal: every adaptive video-only
        /// itag also has one (`1080p`, `720p`, …). Playing those is silent video.
        /// Real muxed progressive (itag 18) looks like
        /// `video/mp4; codecs="avc1.42001E, mp4a.40.2"`.
        var isMuxed: Bool {
            mime.hasPrefix("video/") && url != nil && mime.contains("mp4a")
        }
    }

    struct VideoDetails: Decodable {
        let title: String?
        let author: String?
        let lengthSeconds: String?
        let isLiveContent: Bool?
    }

    /// Non-nil when this client is refused, with a reason worth showing.
    var unplayableReason: String? {
        guard let status = playabilityStatus?.status, status != "OK" else { return nil }
        let reason = playabilityStatus?.reason

        switch status {
        case "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED":
            return reason ?? "This video is age-restricted and needs a signed-in account."
        case "UNPLAYABLE":
            return reason ?? "YouTube won't serve this video to this app."
        case "LIVE_STREAM_OFFLINE":
            return reason ?? "This live stream is offline."
        case "ERROR":
            return reason ?? "This video is unavailable."
        default:
            return reason ?? "YouTube reported: \(status)."
        }
    }

    var hlsURL: URL? {
        guard let raw = streamingData?.hlsManifestUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var bestProgressiveAudioURL: URL? {
        let candidates = (streamingData?.adaptiveFormats ?? [])
            .filter { $0.isProgressiveAudio && $0.isAVPlayerCompatible }
        guard let best = candidates.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }),
              let raw = best.url else { return nil }
        return URL(string: raw)
    }

    var bestMuxedURL: URL? {
        let candidates = ((streamingData?.formats ?? []) + (streamingData?.adaptiveFormats ?? []))
            .filter { $0.isMuxed && $0.isAVPlayerCompatible }
        guard let best = candidates.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }),
              let raw = best.url else { return nil }
        return URL(string: raw)
    }
}
