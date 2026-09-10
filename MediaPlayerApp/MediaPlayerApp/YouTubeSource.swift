import Foundation
import os

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
    /// Set when a progressive audio URL fails on-device, so the rest of the
    /// session serves audio through the HLS endpoint instead (see
    /// `selectPreferredStream` and `filterMasterToAudioOnly`).
    private static let audioFallbackLock = NSLock()
    private static var prefersHLSAudioStorage = false
    static var preferHLSAudio: Bool {
        get {
            audioFallbackLock.lock()
            defer { audioFallbackLock.unlock() }
            return prefersHLSAudioStorage
        }
        set {
            audioFallbackLock.lock()
            prefersHLSAudioStorage = newValue
            audioFallbackLock.unlock()
        }
    }
    static func enableHLSAudioFallback() { preferHLSAudio = true }
    /// The rewritten master has to stay on disk for as long as AVPlayer is using it.
    private static var retainedHLSFile: URL?
    private static let hlsLog = Logger(subsystem: "app.mediaplayer", category: "hls")
    /// Real HLS masters are a few KB. Anything larger is not a master playlist.
    private static let maxMasterBytes = 2 * 1024 * 1024

    /// Called by the player when HLS never starts. The next resolve skips HLS
    /// and takes the best stream the remaining clients offer.
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

    // MARK: - Related videos

    /// Related videos for `item`, mirroring YouTube's own "up next" rail.
    /// Best-effort: returns [] rather than throwing, so a dead endpoint can
    /// never break playback itself.
    func relatedVideos(for item: MediaItem) async -> [MediaItem] {
        guard item.sourceID == id, !item.nativeID.isEmpty,
              let url = URL(string: "\(Self.endpoint)/next") else { return [] }

        for profile in Self.searchClients {
            do {
                let body = NextRequest(
                    videoId: item.nativeID,
                    context: .init(client: .init(profile: profile))
                )
                let data = try await client.postJSON(
                    url: url,
                    body: try JSONEncoder().encode(body),
                    userAgent: profile.userAgent
                )
                let items = Self.parseRelatedVideos(data: data, sourceID: id)
                if !items.isEmpty { return items }
            } catch {
                continue // try the next client
            }
        }
        return []
    }

    /// The /next response no longer uses `compactVideoRenderer` — related
    /// videos arrive as the modern `lockupViewModel` shape (measured live
    /// 2026-09-10: 20 lockups, zero compact renderers), so this parses that:
    /// `contentId` for the video ID, `lockupMetadataViewModel` for title and
    /// author rows, and a thumbnail badge for the duration.
    private static func parseRelatedVideos(data: Data, sourceID: String) -> [MediaItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var lockups: [[String: Any]] = []
        collect(node: root, keys: ["lockupViewModel"], into: &lockups)

        var seen = Set<String>()
        var results: [MediaItem] = []

        for lockup in lockups {
            // Playlists and shorts also arrive as lockups; take videos only.
            // Measured live value: "LOCKUP_CONTENT_TYPE_VIDEO".
            guard let videoID = lockup["contentId"] as? String,
                  seen.insert(videoID).inserted else { continue }
            if let contentType = lockup["contentType"] as? String,
               !contentType.contains("VIDEO") {
                continue
            }

            let metadata = lockup["metadata"] as? [String: Any]
            let lockupMetadata = metadata?["lockupMetadataViewModel"] as? [String: Any]
            let titleNode = lockupMetadata?["title"] as? [String: Any]
            let title = titleNode?["content"] as? String ?? "Untitled"

            // Row 0 is the channel, row 1 is views + age.
            var author = "YouTube"
            var details: [String] = []
            if let contentMetadata = (lockupMetadata?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
               let rows = contentMetadata["metadataRows"] as? [[String: Any]] {
                for row in rows {
                    if let parts = row["metadataParts"] as? [[String: Any]] {
                        for part in parts {
                            if let text = (part["text"] as? [String: Any])?["content"] as? String {
                                details.append(text)
                            }
                        }
                    }
                }
            }
            if let first = details.first { author = first }

            // The duration lives in a thumbnail overlay badge ("25:57").
            var duration: TimeInterval = 0
            if let image = lockup["contentImage"] as? [String: Any],
               let thumb = image["thumbnailViewModel"] as? [String: Any],
               let overlays = thumb["overlays"] as? [[String: Any]] {
                for overlay in overlays {
                    var badges: [[String: Any]] = []
                    collect(node: overlay, keys: ["thumbnailBadgeViewModel"], into: &badges)
                    for badge in badges {
                        if let text = (badge["text"] as? [String: Any])?["content"] as? String {
                            duration = parseDuration(text)
                        }
                    }
                }
            }

            results.append(
                MediaItem(
                    sourceID: sourceID,
                    nativeID: videoID,
                    title: title,
                    author: author,
                    artworkURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg"),
                    duration: duration,
                    kind: .video,
                    streamURL: nil, // resolved lazily at play time
                    detail: details.count > 1 ? details.dropFirst().joined(separator: " · ") : nil
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
                    return await Self.playableURL(url, audioOnly: preferAudioOnly)
                }

                if compromise == nil {
                    compromise = Self.selectAnyStream(from: response, allowHLS: allowHLSGlobally)
                }
            } catch {
                lastError = error
            }
        }

        if let compromise { return await Self.playableURL(compromise, audioOnly: preferAudioOnly) }
        if let refusalReason { throw SourceError.notConfigured(refusalReason) }
        if let lastError { throw lastError }
        throw SourceError.noStream(item.title)
    }

    /// Exactly what was asked for, or nil so the chain tries another client.
    /// When `preferHLSAudio` is set (a progressive audio URL already failed on
    /// this device's network), audio avoids the progressive endpoint entirely:
    /// first the HLS manifest's audio renditions, then muxed progressive — the
    /// muxed itag carries audio too, unlike the broken progressive one.
    private static func selectPreferredStream(from response: PlayerResponse,
                                              preferAudioOnly: Bool,
                                              allowHLS: Bool) -> URL? {
        if preferAudioOnly {
            if allowHLS, preferHLSAudio, let hls = response.hlsURL { return hls }
            if preferHLSAudio, let muxed = response.bestMuxedURL { return muxed }
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
    /// In audio-only mode the rewrite instead keeps just the audio renditions,
    /// which is also the fallback path when progressive audio URLs fail.
    private static func playableURL(_ url: URL, audioOnly: Bool) async -> URL {
        guard looksLikeHLS(url) else { return url }
        let rewritten = audioOnly
            ? await audioOnlyMaster(from: url)
            : await avcOnlyMaster(from: url)
        return rewritten ?? url
    }

    private static func looksLikeHLS(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.contains(".m3u8") || value.contains("manifest/hls")
    }

    /// Fetch the remote master, apply `rewrite` and cache the result locally.
    /// Measured 2026-09-10: the IOS client's master leads with VP9 (10 vs 7
    /// H.264), so AVPlayer's first pick would be VP9.
    ///
    /// The body is streamed with a hard byte cap: `timeoutInterval` is an idle
    /// timeout that resets on every chunk, so it does not bound total transfer,
    /// and buffering an unbounded response into `Data` + `String` + line array
    /// could OOM the process. Real HLS masters are a few KB.
    private static func cachedMaster(from remote: URL, rewrite: (String) -> String) async -> URL? {
        guard remote.scheme?.lowercased() == "https" else { return nil }

        do {
            var request = URLRequest(url: remote)
            request.timeoutInterval = 20
            request.setValue(
                "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)",
                forHTTPHeaderField: "User-Agent"
            )
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else {
                let code = hlsStatusCode(response)
                hlsLog.error("HLS master fetch returned non-2xx (HTTP \(code, privacy: .public))")
                return nil
            }
            if http.expectedContentLength > maxMasterBytes {
                hlsLog.error("HLS master declares \(http.expectedContentLength, privacy: .public) bytes; over cap")
                return nil
            }

            var data = Data()
            data.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxMasterBytes {
                    hlsLog.error("HLS master exceeded \(Self.maxMasterBytes, privacy: .public) bytes; aborting")
                    return nil
                }
            }

            guard let text = String(data: data, encoding: .utf8) else {
                hlsLog.error("HLS master is not valid UTF-8")
                return nil
            }

            let rewritten = rewrite(text)
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
            hlsLog.error("HLS master fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func hlsStatusCode(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private static func avcOnlyMaster(from remote: URL) async -> URL? {
        cachedMaster(from: remote, rewrite: filterMasterToAVC)
    }

    /// Audio-only master: one variant per TYPE=AUDIO rendition, no video.
    /// Used when progressive audio URLs fail on the device's network path
    /// (measured on-device: progressive `videoplayback` requests die with
    /// NSURLErrorDomain -1 while the HLS playlist endpoint keeps serving).
    private static func audioOnlyMaster(from remote: URL) async -> URL? {
        cachedMaster(from: remote, rewrite: filterMasterToAudioOnly)
    }

    /// Keep H.264 video + the AAC audio groups those variants reference.
    ///
    /// Kept STREAM-INF lines also lose their `SUBTITLES` attribute: every
    /// `TYPE=SUBTITLES` rendition is dropped below, and a variant that still
    /// names the group would reference a rendition that no longer exists
    /// (RFC 8216 §4.3.4.2 — Apple's HLS tooling rejects the dangling reference).
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
                    output.append(strippingSubtitlesAttribute(from: line))
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

    /// Audio-only master: one variant per TYPE=AUDIO rendition, no video.
    /// Used when progressive audio URLs fail on the device's network path —
    /// measured on-device: progressive `videoplayback` requests die with
    /// NSURLErrorDomain -1 while the HLS playlist endpoint keeps serving.
    /// The TYPE=AUDIO media lines are kept so each variant's AUDIO="group"
    /// reference still resolves (no dangling groups).
    static func filterMasterToAudioOnly(_ playlist: String) -> String {
        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)
        var media: [String] = []
        var variants: [(header: String, uri: String)] = []

        for line in lines {
            guard line.hasPrefix("#EXT-X-MEDIA:"),
                  attribute(named: "TYPE", in: line) == "AUDIO",
                  let uri = attribute(named: "URI", in: line) else { continue }
            media.append(line)
            let group = attribute(named: "GROUP-ID", in: line) ?? ""
            variants.append((
                "#EXT-X-STREAM-INF:BANDWIDTH=129000,CODECS=\"mp4a.40.2\",AUDIO=\"\(group)\"",
                uri
            ))
        }

        guard !variants.isEmpty else { return playlist }

        var output = ["#EXTM3U", "#EXT-X-INDEPENDENT-SEGMENTS"]
        output.append(contentsOf: media)
        for (header, uri) in variants {
            output.append(header)
            output.append(uri)
        }
        return output.joined(separator: "\n") + "\n"
    }

    /// Removes `SUBTITLES="<group>"` from a kept STREAM-INF line so the
    /// rewritten master has no variants naming the dropped subtitle group.
    /// YouTube masters always quote the value; if one ever doesn't, the line
    /// is passed through untouched rather than mangled.
    private static func strippingSubtitlesAttribute(from line: String) -> String {
        guard let start = line.range(of: ",SUBTITLES=\"") else { return line }
        let tail = line[start.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return line }
        return String(line[..<start.lowerBound] + tail[end...].dropFirst())
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

private struct NextRequest: Encodable {
    let videoId: String
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
