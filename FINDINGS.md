# Why the YouTube/Invidious design was abandoned

Measured on 2026-08-26 from a normal residential connection, before any code was
changed. The original app's core premise — "public Invidious instances give you
ad-free YouTube with no API key" — does not hold.

## What the official instance list says

`GET https://api.invidious.io/instances.json?sort_by=type,users`

The two highest-ranked instances both report:

| Field | inv.nadeko.net | invidious.nerdvpn.de |
|---|---|---|
| `api` | `false` | `false` |
| `playback.totalRequests` | 15 | 44 |
| `playback.successfulRequests` | **0** | **0** |
| `playback.ratio` | **0.0** | **0.0** |

`api: false` means the `/api/v1` surface the app depends on is switched off.
A playback success ratio of `0.0` means the instance cannot fetch media from
YouTube at all — Google blocks datacenter IP ranges.

## What the endpoints actually return

`GET /api/v1/search?q=test&type=video`

| Instance | Result |
|---|---|
| `inv.nadeko.net` | HTTP 403 Forbidden |
| `invidious.nerdvpn.de` | HTTP 401 Unauthorized |
| `invidious.f5.si` | HTTP 200 — but the body is an **Anubis proof-of-work challenge page** (`<title>Making sure you're not a bot!</title>`), not JSON |
| `yewtu.be` | HTTP 200 — but the body is a **browser-verification page** (`<title>Verifying your browser…</title>`), not JSON |
| `invidious.jing.rocks` | DNS name no longer resolves |

`GET /api/v1/videos/dQw4w9WgXcQ` on `yewtu.be` returns 403 even though its
search path returned 200.

Two of the five instances hard-coded in the original `YouTubeService.swift`
(`invidious.snopyta.org`, `invidious.perflystis.io`) do not exist, and
`yewtu.be` was listed twice.

## Why no amount of code fixing helps

An HTTP 200 carrying a JavaScript proof-of-work challenge cannot be satisfied by
`URLSession`. Solving it requires executing the challenge script in a browser
engine and returning a signed cookie. Working around that deliberately is both
fragile and hostile to operators who put it there specifically to stop automated
clients.

Separately: extracting YouTube streams to strip ads is contrary to YouTube's
Terms of Service, regardless of the technical route.

## What was verified as working instead

Each of these was tested end to end — discovery, metadata, and a real byte-range
request against the media URL.

**Apple Podcasts directory** — `itunes.apple.com/search`

```
media=podcast&entity=podcastEpisode  -> JSON with direct episodeUrl
media=podcast&entity=podcast         -> JSON with feedUrl (RSS)
```
Episode enclosure HEAD: `HTTP 200`, `Content-Type: audio/mpeg`,
`Accept-Ranges: bytes`. No key, no quota signup.

**Internet Archive** — `archive.org`

```
/advancedsearch.php?q=...&output=json  -> 13,100,431 audio items matched
/metadata/{identifier}                 -> full file list
/download/{identifier}/{file}          -> HTTP 200, audio/mpeg,
                                          Accept-Ranges: bytes, 36 MB
```

**Local files** — no network, no third party, cannot break.

`Accept-Ranges: bytes` is the part that matters: it is what lets `AVPlayer`
stream progressively and seek instead of buffering whole files.

## Piped is also unusable

Piped is a separate project with its own instances. Same test, `GET /streams/dQw4w9WgXcQ`:

| Instance | Result |
|---|---|
| `pipedapi.kavin.rocks` | HTTP 525 (TLS handshake failure) |
| `pipedapi.adminforge.de` | HTTP 403 Forbidden |
| `api.piped.private.coffee` | DNS does not resolve |
| `pipedapi.drgns.space` | HTTP 200, `Content-Type: text/html` — not JSON |

So *no* public proxy network works. Any proxy-based design requires self-hosting.

---

# On-device extraction does work

Rather than proxying through someone else's server, the app talks to YouTube's
own internal API ("InnerTube", `/youtubei/v1/*`) directly — the same protocol
YouTube's own apps use. The client identity you claim changes everything:

`POST /youtubei/v1/player`

| Client | playabilityStatus | Formats | Cipher needed | PO Token | Stream fetch |
|---|---|---|---|---|---|
| **IOS** | OK | 27 adaptive | **none** | **not required** | HTTP 206 `audio/mp4` |
| ANDROID_VR | OK | 27 (1 muxed) | none | not required | HTTP 206 `video/mp4` |
| WEB | **UNPLAYABLE** | 0 | — | required | — |

The `IOS` client is the useful one, and this is why:

- **All 27 formats carry a plain `url`.** No `signatureCipher`, so there is no
  need to download and interpret YouTube's player JavaScript — which is the
  fragile, heavyweight part of every other extractor.
- **No PO Token.** The `WEB` client is refused outright without BotGuard
  attestation. The iOS client is not.
- **No API key** in the request at all.
- **HLS manifest is present and fetchable**, exposing 8 renditions up to
  **3840x2160**. `AVPlayer` plays HLS natively with adaptive bitrate, so this is
  strictly better than the 720p muxed ceiling a proxy would have given.
- **The URLs are User-Agent agnostic.** This mattered: `AVPlayer` sends
  `AppleCoreMedia/1.0.0...`, not the app's UA. Tested all three:

  | Requesting UA | m4a audio | HLS master |
  |---|---|---|
  | YouTube-app UA | HTTP 206 | HTTP 200 |
  | `AppleCoreMedia` | **HTTP 206** | **HTTP 200** |
  | empty | HTTP 206 | HTTP 200 |

There's also a neat side effect: googlevideo URLs are IP-bound, which is exactly
why a proxy's URLs 403 from the phone. Extracting *on the device* means the URL
is bound to the device's own IP, so it just works.

## Why this is ad-free

Nothing is being blocked, which is what makes it robust. Ads are injected by
YouTube's *player* as separate playback requests, described by `adPlacements` in
the player response. The content stream contains no advertising. Requesting the
media URL directly means an ad is never part of the pipeline.

Verified:

- `adPlacements`: **0 entries**
- HLS master playlist: no `EXT-X-DATERANGE`, `EXT-X-CUE-OUT`, `SCTE35`,
  `EXT-X-ASSET` or `EXT-X-SPLICEPOINT`
- HLS media playlist: same, no splice markers

Progressive `adaptiveFormats` URLs cannot carry server-side inserted ads at all,
so audio-only mode is structurally immune. HLS is preferred for video because of
the quality range; a Settings toggle switches to progressive if you'd rather have
the structural guarantee than 4K.

## Search

The `IOS` client serialises search results into base64 protobuf blobs inside
`elementRenderer`, which is impractical to parse. The `WEB` client still returns
conventional `videoRenderer` objects with title, `lengthText`, channel,
thumbnails and view count — and search is *not* gated the way the player is.

So the app uses two clients: `WEB` to search, `IOS` to resolve streams.

## Redundancy across client identities

A single client is a single point of failure, so all nine identities worth trying
were surveyed (`scripts/probe-clients.py`, same video):

| Client | playabilityStatus | Audio | Muxed | HLS | Cipher | Fetch |
|---|---|---|---|---|---|---|
| **IOS** | OK | 2 | 0 | **yes** | 0 | 206 |
| **ANDROID_VR** | OK | 2 | 1 | no | 0 | 206 |
| **ANDROID** | OK | 3 | 1 | no | 0 | 206 |
| IOS_MUSIC | LOGIN_REQUIRED | 0 | 0 | no | 0 | — |
| TVHTML5 | UNPLAYABLE | 0 | 0 | no | 0 | — |
| TVHTML5_SIMPLY_EMBEDDED_PLAYER | ERROR | 0 | 0 | no | 0 | — |
| MWEB | UNPLAYABLE | 0 | 0 | no | 0 | — |
| WEB_EMBEDDED_PLAYER | ERROR | 0 | 0 | no | 0 | — |
| WEB | UNPLAYABLE | 0 | 0 | no | 0 | — |

Three work independently. The app walks them in rank order, treats a refusal as
per-client rather than per-video, and remembers which one last succeeded. YouTube
would have to close three doors at once to stop playback.

`IOS` is ranked first as the only source of `hlsManifestUrl`; the Android clients
are the safety net and additionally supply muxed progressive formats, which `IOS`
does not return at all.

## Which further features are reachable

Surveyed to decide whether this app can close the gap with the real YouTube app.
Renderer names and working clients differ per endpoint, so both were tried:

| Endpoint | Purpose | WEB | ANDROID_VR |
|---|---|---|---|
| `next` | related / autoplay next | 21 videos | 20 |
| `browse FEwhat_to_watch` | home feed | empty | **68** |
| `browse UC… + EgZ2aWRlb3M%3D` | channel uploads | **80** | 67 |
| `browse VL…` | playlist contents | **100** | 20 |
| `sponsor.ajay.app/api/skipSegments` | SponsorBlock | reachable | — |

So home feed, autoplay/related, channel browsing, playlists and sponsor-segment
skipping are all implementable with the same verified extraction path.

**Not reachable without a signed-in account:** subscriptions, watch history,
Likes, posting comments, and personalised recommendations. Those need OAuth
against a Google account, which is a different and much larger problem — and the
part where a patched official client genuinely wins.

## Newer client versions are not better

Worth recording because it contradicts the obvious instinct. The current App Store
YouTube version is discoverable at runtime (`itunes.apple.com/lookup?id=544007664`
returned `21.34.3`, released 2026-08-25), so the app *could* self-update its client
version. Testing whether it should:

| iOS client version | playabilityStatus | Audio formats | HLS | Verdict |
|---|---|---|---|---|
| 19.29.1 | HTTP 400 | — | — | too old, rejected |
| 20.03.02 | OK | 2 | yes | good |
| 20.10.4 | OK | 2 | yes | good |
| 20.30.2 | OK | 2 | yes | good |
| 21.10.1 | OK | 2 | yes | good |
| **21.34.3** (current) | **OK** | **0** | yes | **video only — audio-only breaks** |

The newest version reports success and serves video perfectly well, but returns no
progressive audio formats at all. Auto-tracking the latest release would therefore
have silently broken audio-only playback — the failure mode that matters most for
music, and one that wouldn't look like a failure.

So the app pins several verified-good versions and falls through them instead. The
fallthrough composes with audio-only requests naturally: a client with no audio
formats yields nil and the chain moves to the next, so losing audio support in one
version degrades to "skipped" rather than "broken".

Re-check with `scripts/probe-versions.py`, which also reports the current App
Store version and appends it to the candidate list automatically.

Related: the pinned `WEB` search version (`2.20250312.04.00`) is around 17 months
behind the live value (`2.20260824.10.00`, scrapeable from the homepage as
`INNERTUBE_CLIENT_VERSION`) and search still works fine. YouTube is far more
lenient about the search client than the player client.

## Honest caveats

1. **This is contrary to YouTube's Terms of Service.** Personal, non-distributed,
   on your own device — but the app doesn't pretend otherwise.
2. **It needs occasional upkeep.** YouTube rotates accepted client versions. The
   three-client chain makes one closure survivable rather than fatal, but the
   version strings do eventually need refreshing. `probe-clients.py` warns when
   redundancy drops to a single client — before total failure.
3. **These measurements come from a desktop, not an iPhone.** The iOS client path
   should behave at least as well from a real device, since it genuinely *is*
   that client, but on-device behaviour is unverified.
4. **Commercial apps that never seem to break** generally rely on a server-side
   extractor maintained continuously by a team; the labour is hidden, not absent.
   An app that streams YouTube while showing its own ads is usually either using
   the official embed player (ads included, very stable) or injecting its own
   monetisation — neither indicates a more durable extraction method.

## Consequence for the app

The source layer is a protocol (`MediaSource`) with five implementations, so a
backend dying is a one-file problem rather than a total loss. YouTube is primary
and its results lead the list. Podcasts, Internet Archive and local files stay
enabled as zero-maintenance fallbacks that cannot be broken by a YouTube change.
Self-hosted Invidious remains available as an optional backup.
