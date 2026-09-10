# MediaPlayerApp — architecture and internals

Companion to [README.md](README.md) (setup and install) and
[FINDINGS.md](FINDINGS.md) (why the backend changed).

## Shape of the app

```
MediaPlayerApp (@main)
│  owns one PlayerEngine, one Library, one SourceRegistry
│  injected via .environmentObject
▼
RootView ─ TabView
├── BrowseView       search every enabled source, interleaved
├── LibraryView      favorites / recent / local files
├── SettingsView     source toggles, self-hosted host entry
└── MiniPlayerView   safeAreaInset on each tab, opens NowPlayingView

PlayerEngine (@MainActor, ObservableObject)
├── one long-lived AVPlayer          items swapped via replaceCurrentItem
├── queue + currentIndex             shuffle is a permutation, not per-step random
├── RepeatMode + isShuffled          independent, so neither is a dead end
├── NowPlayingController             MPRemoteCommandCenter + MPNowPlayingInfoCenter
└── resolves streams through SourceRegistry

SourceRegistry (@MainActor)
├── YouTubeSource       PRIMARY — on-device InnerTube extraction
├── PodcastSource       iTunes Search API + RSS enclosures
├── ArchiveSource       archive.org advancedsearch + metadata
├── LocalFilesSource    Documents/Media
└── InvidiousSource     optional self-hosted fallback, inert until configured

HTTPClient (actor)   one URLSession, explicit timeouts, status + content-type checks
```

## The source abstraction

```swift
protocol MediaSource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var systemImage: String { get }
    var blurb: String { get }
    var isAvailable: Bool { get }

    func search(query: String) async throws -> [MediaItem]
    func resolveStream(for item: MediaItem, preferAudioOnly: Bool) async throws -> URL
}
```

Two-phase by design. `search` returns lightweight `MediaItem`s; `resolveStream`
does any second round trip needed to get a playable URL, at play time. Podcasts
and local files know their URL up front and use the protocol's default
implementation. Archive.org and Invidious need a metadata lookup.

`SourceRegistry.searchAll` fans out with a task group and round-robin merges the
per-source results, so no backend dominates the list. A source that throws
contributes a message to `failures` instead of blanking the screen — the whole
point of the abstraction is that one dead backend is survivable.

`MediaItem.id` is `"<sourceID>:<nativeID>"`, so identity is globally unique and
stable across launches, and the engine can always find the source that produced
an item.

Results from `SourceRegistry.primarySourceID` (`"youtube"`) are placed ahead of
everything else rather than being round-robined, so the primary source leads
without secondary sources becoming unreachable.

## YouTubeSource

Talks to YouTube's internal InnerTube API (`/youtubei/v1/*`) using **two client
identities**, because each is good at a different job:

| Purpose | Client | Why |
|---|---|---|
| Search | `WEB` | returns conventional `videoRenderer` objects with title, `lengthText`, channel, thumbnails |
| Streams | `IOS` | returns **un-ciphered** URLs and an HLS manifest, and needs no PO Token |

The `IOS` client is what makes this viable without a server:

- every format carries a plain `url`, so no player-JavaScript interpreter is
  needed — this is the fragile, heavyweight part of every other extractor
- no PO Token / BotGuard attestation, unlike `WEB`, which is refused outright
- no API key
- `hlsManifestUrl` gives 17 renditions up to 3840×2160 (7 H.264 after the
  avc-only rewrite below)
- URLs are User-Agent agnostic, which matters because AVPlayer sends
  `AppleCoreMedia`, not the app's UA

Because extraction happens on the device, the IP-bound googlevideo URL is bound
to the *device's* IP. That is precisely the thing that makes proxy-based designs
403 from the phone.

### Stream selection

```
audio-only  -> best-bitrate audio/mp4 from adaptiveFormats
video       -> avcOnlyMaster(hlsManifestUrl)  (unless "prefer progressive" is set)
            -> muxed progressive from formats
            -> retry via ANDROID_VR, which reliably returns a muxed format
            -> audio as a last resort
```

`adaptiveFormats` split video and audio into separate URLs that AVPlayer cannot
recombine from two remote sources, so only *muxed* progressive formats are usable
standalone — and the `IOS` client returns none, which is why `ANDROID_VR` exists
as a fallback. WebM/Opus/Vorbis are filtered out; AVPlayer can't decode them.

The raw `hlsManifestUrl` is not handed to AVPlayer directly. The IOS client's
HLS master lists VP9 renditions first (measured: 10 VP9 vs 7 H.264), and AVPlayer
on device picks VP9 and stalls forever — the item never reaches `.failed`, so
normal retry logic never fires. `YouTubeSource.avcOnlyMaster` instead fetches the
master with an `AppleCoreMedia` user agent, rewrites it to keep only `avc1`
variants plus the `TYPE=AUDIO` groups they reference (dropping `vp09`, `av01`,
and `TYPE=SUBTITLES` lines), writes the result to `yt-hls-<uuid>.m3u8` in Caches,
and hands that local file to AVPlayer. If a rewritten stream still never starts,
`PlayerEngine.watchForStall` fires after 8 seconds of no playback, adds the video
ID to a session skip set, and re-resolves through the muxed fallbacks above.

### Response parsing

Split deliberately:

- **Player response** — stable schema, decoded strictly with `Codable`.
- **Search response** — wrapper renderers change shape often, so it's walked as
  loose JSON (`JSONSerialization`) looking for `videoRenderer` /
  `compactVideoRenderer` nodes. The *inside* of those nodes has been stable for
  years; the scaffolding around them has not. Thumbnails are constructed from the
  video ID rather than parsed out, which is one less thing to break.

### Resilience: the client chain

A single client identity is a single point of failure. `playerClients` is a ranked
list and `resolveStream` walks it until one produces a usable stream, so YouTube
has to close several doors at once to break playback. Measured, all three of
these independently return fetchable streams:

| Client | Rank | Why it's in the list |
|---|---|---|
| `IOS` | 1 | only one exposing `hlsManifestUrl` — adaptive up to 4K |
| `ANDROID_VR` | 2 | audio + a muxed progressive format |
| `ANDROID` | 3 | audio (3 tracks) + muxed |

Refusals are treated as **per-client, not per-video**: a `LOGIN_REQUIRED` from one
identity records the reason and moves on, because another identity may still be
served. Only if every client fails is the reason surfaced.

The last client that worked is remembered in `UserDefaults` and moved to the front
of the chain, so a client that YouTube has retired doesn't get re-tried first on
every single playback.

Search has its own two-client chain (`WEB`, then `ANDROID_VR`).

A brief note on how this compares to commercial apps that appear never to break:
their stability generally comes from a **server-side** extractor that a team
updates continuously — the maintenance is real, it's just invisible to you.
Anything that streams YouTube while showing its own ads is usually either using
the official embed player (ads included, very stable) or injecting its own
monetisation. Neither implies a more durable extraction technique. The levers
actually available to a client-side implementation are the two used here:
redundancy across clients, and fallback to sources that can't break at all.

### Maintenance

The section marked `MAINTENANCE: client identities` holds every version string —
the only values that routinely go stale.

| Script | Answers |
|---|---|
| `scripts/probe-clients.py` | which client identities currently work |
| `scripts/probe-youtube.py` | which pipeline stage broke (search / player / fetch / ads) |
| `scripts/probe-versions.py` | which iOS client versions still return progressive audio |

Do **not** simply adopt the newest client version. The current App Store release
returned `OK` plus a working HLS manifest but zero progressive audio formats,
which breaks audio-only playback while appearing healthy. Several verified-good
versions are pinned in the chain for exactly this reason.

`probe-clients.py` exits non-zero when nothing works and warns when redundancy
drops to one client, which is the point to refresh versions rather than waiting
for total failure. Cross-check current values against
[yt-dlp](https://github.com/yt-dlp/yt-dlp), which tracks the same clients.

## Playback

One `AVPlayer` for the process lifetime. Items are swapped with
`replaceCurrentItem(with:)`; the periodic time observer is added once in `init`
and removed once in `deinit`. Per-item observation uses Combine
(`playerItem.publisher(for: \.status)`) with a `Set<AnyCancellable>` that is
cleared on every swap, so observers are detached deterministically.

`isPlaying` is derived from `player.timeControlStatus` rather than set by hand,
which keeps it correct when playback changes for reasons the app didn't
initiate — lock-screen buttons, interruptions, route changes.

Speed uses `player.defaultRate` (iOS 16+) so `play()` resumes at the chosen rate
instead of snapping to 1×.

Every duration and progress value passes through `Formatters.progress` /
`Formatters.duration`, which reject non-finite input. `AVPlayer` reports `NaN`
duration until an item is ready, and a `NaN` frame width crashes the SwiftUI
render pass.

Stream URLs from some sources expire. On `.failed` or
`AVPlayerItemFailedToPlayToEndTime`, the engine re-resolves the URL once and
resumes at the current position, guarded by a flag so it can't loop.

## Lock screen

`NowPlayingController` registers remote commands exactly once, and separates
metadata updates from playback-state updates:

- `update(item:duration:engine:)` rebuilds the dictionary on track change
- `refreshPlaybackState()` touches only elapsed time and rate

Artwork is fetched once per URL and cached for the session, and applied only if
the track hasn't changed while the download was in flight.

## Video

`VideoSurface` is a `UIViewRepresentable` over a `UIView` whose `layerClass` is
`AVPlayerLayer`, so UIKit keeps the layer's frame in sync through rotation and
resize with no manual bookkeeping. It also constructs the
`AVPictureInPictureController`, handed up to a `PiPCoordinator` so a SwiftUI
button can drive it.

AirPlay is a real `AVRoutePickerView`.

### Screen-off playback

Declaring `UIBackgroundModes: [audio]` is necessary but **not sufficient**: iOS
suspends an `AVPlayer` that still has a video layer attached when the app leaves
the foreground. So `PlayerHostView` observes
`UIApplication.didEnterBackgroundNotification` and sets `playerLayer.player = nil`,
releasing the video output while the engine keeps its own strong reference and
playback continues as audio. `willEnterForegroundNotification` restores it.

Two guards around that:

- if Picture-in-Picture is active the layer stays attached, since PiP renders in
  the background on purpose
- `updateUIView` goes through `syncPlayer(_:)` rather than assigning directly, so
  a SwiftUI update while backgrounded can't silently re-attach the layer and
  re-suspend playback

Audio-only mode sidesteps this entirely — no video track is requested, and
`NowPlayingView` shows artwork instead of a player layer.

## Persistence

| Data | Where |
|---|---|
| Favorites, recents | `Application Support/library.json`, atomic writes |
| Imported media | `Documents/Media/` |
| Source on/off, Invidious host | `UserDefaults` |

Local items resolve by *filename*, not absolute path. The app container path
changes between installs and after a SideStore re-sign, which would otherwise
invalidate every saved local item.

## Concurrency

`PlayerEngine`, `Library`, `SourceRegistry`, `NowPlayingController` and the view
models are `@MainActor`. `HTTPClient` is an `actor`. Sources are `Sendable`
structs. Task groups carry only `Sendable` payloads — failures cross boundaries
as pre-rendered strings, because `Error` is not `Sendable`.

## What changed from the previous version

The previous code did not compile. Beyond that, the defects worth recording:

**Would not build**

- `project.pbxproj` reused the same 24-hex object IDs for unrelated objects — one
  ID was simultaneously a `PBXBuildFile`, a `PBXFileReference` and an
  `XCBuildConfiguration`. Build phases listed file-reference IDs where
  build-file IDs belong; the project's config list pointed at a build phase.
- No shared scheme, so `xcodebuild -scheme MediaPlayerApp` could not resolve.
- `Info.plist` was in the Resources build phase *and* set as `INFOPLIST_FILE`.
- The asset catalog declared 22 PNGs, none of which existed, and mapped one
  filename to two different pixel sizes.
- `SearchViewModel.playItem` referenced an `audioManager` that wasn't in scope.
- `SearchView` read `YouTubeService.instances` and `.currentInstance`, both `private`.
- Views read `audioManager.player` and `.isAudioOnlyMode`, both `private`.
- `FavoritesView` called `favoritesManager.saveFavorites()`, `private`.

**Crashes**

- `MiniPlayerView` force-unwrapped `currentItem!` twice inside its body.
- A KVO observer was added to every `AVPlayerItem` and only ever removed from the
  last one — "deallocated while key value observers were still registered".
- The periodic time observer was removed from the *new* `AVPlayer` after the
  property had already been reassigned, so it leaked on the old player and
  risked a trap for being removed from a player it was never added to.
- `NaN` duration flowed unguarded into progress-bar frame widths.

**Wrong behaviour**

- `type == "audio"` never matched, because the API returns
  `audio/mp4; codecs="mp4a.40.2"`. Audio-only mode silently played video.
- `container == "mp4" && quality.contains("720") || quality.contains("1080")`
  parses as `(mp4 && 720) || 1080`, so it could select a non-MP4 format.
- Failover recursed into the function that called it while mutating a shared
  index, making its termination condition unreliable; it also only triggered on
  non-200, not on thrown errors.
- The instance list contained a duplicate and two hosts that don't exist.
- Repeat-off wrapped to the start of the queue, identically to repeat-all.
- Shuffle picked `Int.random` per advance, so it repeated tracks and never
  covered the queue; the loop button cycled a three-element array that excluded
  shuffle, so once shuffled there was no way back.
- Now-playing artwork was re-downloaded from the network twice per second.
- `MediaItem.formattedDuration` rendered 2h05m as `125:30`.
- The video screen's "skip forward" button called `playNext()`.
- The mini player was overlaid on the `TabView`, covering the tab bar.
- PiP, AirPlay, "Start Exploring" and instance selection were dead controls.
- Two `AudioManager` instances existed: a `shared` singleton and a `@StateObject`.

**Configuration**

- `UIRequiredDeviceCapabilities` was `armv7`, a 32-bit slice no iOS 17 device
  has, which fails install validation.
- `NSAllowsArbitraryLoads` disabled TLS enforcement app-wide. Now ATS is on, with
  `NSAllowsLocalNetworking` only, so a LAN Invidious host over HTTP still works.
- `remote-notification` background mode was declared with no push handling, and a
  free Apple ID cannot sign that entitlement.
- A microphone usage string was present for a feature the app doesn't have.

**Dead code**

- `SearchResult`, `YouTubeVideo`, `VideoID`, `VideoSnippet`, `Thumbnails`,
  `ThumbnailInfo`, `VideoContentDetails` — leftovers from the official YouTube
  Data API, unused once Invidious was adopted.
- `setCustomInstance` printed to the console and did nothing.

## Extending it

**A new source.** Implement `MediaSource`, add it to `SourceRegistry.all`. It
appears in Settings and joins Browse automatically. Good candidates with open
APIs: Jamendo, Free Music Archive, NASA's media library, Openverse, an OPDS
audiobook server, or your own Jellyfin/Navidrome instance.

**Offline download.** Add a `download(item:)` to `LocalFilesSource` that streams a
resolved URL to `Documents/Media/`; existing local playback then covers it.

**Lyrics / chapters.** Podcast RSS often carries chapter data
(`podcast:chapters`); `RSSParser` is where to pick it up.

**Widgets or Shortcuts.** `PlayerEngine`'s published state is already the single
source of truth; add WidgetKit or `AppIntents` on top.

## Verification status

| Check | How | Result |
|---|---|---|
| YouTube pipeline | `scripts/probe-youtube.py` | PASS — 12/12: search, un-ciphered URLs, 4K HLS, AppleCoreMedia fetch, no ad markers |
| Backend reachability | live HTTP probes | Podcasts + Archive.org verified; Invidious and Piped dead (FINDINGS.md) |
| Project file integrity | `scripts/validate-project.ps1` | PASS — 63 objects, no duplicate or dangling IDs |
| Swift structure | `scripts/lint-swift.ps1` | PASS — 20 files, balanced, no stale references |
| App icon validity | 1024×1024, `Format24bppRgb` | PASS — opaque, no alpha |
| Workflow YAML | parsed with PyYAML | PASS — 7 steps, `macos-15` runner |
| Compilation | requires Xcode | **not run here** — no iOS toolchain on Windows; run the CI job |
| On-device behaviour | requires an iPhone | **not run here** |

The last two are the honest gaps. Everything checkable without a Mac has been
checked, and each script was confirmed to *fail* on broken input rather than
passing vacuously: the project validator was given an orphaned source file, the
Swift linter caught a genuine nested-type false positive that was then fixed, and
the YouTube probe was run against an invalid video ID (exit 1, 3 failures named).
