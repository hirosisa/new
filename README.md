# Media Player — personal ad-free iOS player

Native SwiftUI audio/video player for iPhone. **YouTube without ads**, plus
podcasts, Internet Archive and your own files. No accounts, no API keys, no
tracking, no server to run. Installs with a free Apple ID via SideStore.

| Source | Setup | Content |
|---|---|---|
| **YouTube** | none | primary source — search and play, up to 4K, no ads |
| **Podcasts** | none | Apple's public directory — millions of shows |
| **Internet Archive** | none | 13M+ audio items, plus public-domain film |
| **My Files** | none | audio/video you copy in; works offline |
| Invidious | your own server | optional fallback, off by default |

## How the ad-free part works

Nothing is blocked, which is why it's reliable. The app talks to YouTube's own
internal API (the one YouTube's apps use) with an **iOS client identity**, and
gets back direct media URLs. Ads are injected by YouTube's *player* as separate
playback requests — when you request the media stream directly, an ad is never
part of the pipeline.

Measured against the live API:

- Stream URLs come back **un-ciphered** — no player-JavaScript interpreter needed
- **No PO Token and no API key** required (the `WEB` client is refused; iOS isn't)
- HLS manifest exposes 8 renditions up to **3840×2160**, played natively by AVPlayer
- `adPlacements`: **empty**. No `SCTE35` / `EXT-X-CUE-OUT` / `EXT-X-DATERANGE`
  splice markers in either the master or media playlist
- URLs are User-Agent agnostic, so `AVPlayer`'s own `AppleCoreMedia` UA works

Full measurements in [FINDINGS.md](FINDINGS.md).

## How durable is it?

Three **independent** client identities currently return playable streams, and the
app walks them in order until one works:

| Client | Provides | Status |
|---|---|---|
| `IOS` | HLS up to 4K + audio | works |
| `ANDROID_VR` | audio + muxed progressive | works |
| `ANDROID` | audio + muxed progressive | works |
| `WEB`, `MWEB`, `TVHTML5`, `IOS_MUSIC` | — | refused |

So a single client being tightened is survivable rather than fatal. The client
that last worked is remembered and tried first. Check the current state any time:

```
python scripts/probe-clients.py
```

It warns when redundancy drops to one client — that's the moment to refresh
version strings, rather than waiting for total failure.

Underneath, Podcasts, Internet Archive and your own files stay enabled and cannot
be broken by any YouTube change. Local files can't break at all.

Two things to know honestly. **This is contrary to YouTube's Terms of Service** —
personal use on your own device, but the app doesn't pretend otherwise. And it
**does need occasional maintenance**: apps that seem never to break usually have a
team updating a server-side extractor for you, which is hidden work rather than a
more durable technique.

Public Invidious *and* Piped instances are all dead — 401/403, DNS gone, or
bot-check pages instead of JSON. That's why extraction happens on-device instead.

## Building without macOS

Compiling an iOS app requires Xcode, and Xcode is macOS-only — the iOS SDK ships
only inside it and can't be redistributed, so there is no legitimate local
Windows path. What you can do is use someone else's Mac in the cloud without
owning one:

| Option | Mac needed | Cost | Notes |
|---|---|---|---|
| **GitHub Actions** (included) | no | free tier on personal accounts | recommended; workflow already written |
| Codemagic | no | free tier | connect the repo, macOS runners |
| Bitrise | no | free tier | same idea |
| MacinCloud / MacStadium | no | hourly / monthly rental | a real remote Mac |
| Your own Mac | yes | — | `scripts/build-unsigned-ipa.sh` |

Signing does **not** need a Mac either — SideStore signs the `.ipa` on the iPhone
itself with your Apple ID.

Avoid the online "IPA signing" services that ask for your Apple ID password.
They need full account credentials, and SideStore does the same job locally.

## Features

Everything listed here is implemented and wired up:

- Background audio with the screen off and the app backgrounded
- Lock screen / Control Center / CarPlay controls, with artwork
- Repeat off / all / one, and shuffle as an independent toggle
- Playback speed 0.75×–2×, persisted across tracks
- Queue with drag reorder and swipe delete
- Favorites and recently-played, stored on device
- Sleep timer
- Real Picture-in-Picture for video (`AVPictureInPictureController`)
- System AirPlay picker
- Audio-only mode for video, resuming at the same position
- Search across all enabled sources at once, YouTube results first
- Audio-only mode for music: streams just the audio track, persists between launches
- Import your own files; they play offline and never expire
- Automatic retry when a stream URL expires mid-playback

## Getting it onto your iPhone without a Mac

### 1. Build the IPA in the cloud

```
git init
git add .
git commit -m "Media player"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

Then on GitHub: **Actions → Build unsigned IPA → Run workflow**. When it
finishes, download the `MediaPlayerApp-unsigned-ipa` artifact and unzip it to get
`MediaPlayerApp-unsigned.ipa`.

The workflow builds for `arm64`, packages the `.ipa`, and fails the build if the
binary is the wrong architecture or if `UIBackgroundModes` has lost `audio`
(which would silently break screen-off playback).

A private repo is fine. Actions gives free macOS runner minutes on personal
accounts; this build takes a couple of minutes.

### 2. Install SideStore (one USB connection, once)

1. Get SideStore for Windows from <https://sidestore.io>
2. Connect the iPhone by cable and install SideStore onto it
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → on**, restart
4. **Settings → General → VPN & Device Management** → trust your Apple ID
5. Pair the device in SideStore — this writes a pairing file, and after this no
   cable is ever needed again

### 3. Install the app

Put the `.ipa` on the iPhone (iCloud Drive, AirDrop, or a USB copy), then in
SideStore tap **+** and pick it. SideStore signs it with your Apple ID and
installs it.

### 4. Refresh

A free Apple ID signs apps for 7 days. SideStore re-signs in the background over
its local VPN, so in practice you don't touch it. If it ever lapses, open
SideStore and tap **Refresh All**.

## Setting the bundle identifier

Default is `com.example.mediaplayer`. Change it if you hit a conflict or want
several builds side by side — edit `PRODUCT_BUNDLE_IDENTIFIER` in
`MediaPlayerApp/MediaPlayerApp.xcodeproj/project.pbxproj` (two places, Debug and
Release).

A free Apple ID allows 10 App IDs at a time and 3 devices.

## Adding your own media

Library → **Files** → **+**, or drop files into the app's Documents folder from
Finder/iTunes file sharing, or AirDrop them. Supported: mp3, m4a, m4b, aac, wav,
aiff, caf, mp4, m4v, mov.

These are the most reliable content in the app. No expiry, no network, no
third-party service that can change its mind.

## When YouTube breaks

Two diagnostics, run from the project folder:

```
python scripts/probe-youtube.py     # which pipeline stage broke
python scripts/probe-clients.py     # which client identities still work
python scripts/probe-versions.py    # which iOS client versions still return audio
```

**Don't just bump to the newest version.** Measured: the current App Store release
returned `OK` with a working video manifest but zero audio formats, which breaks
audio-only playback while looking fine. `probe-versions.py` tells you which
versions are actually safe; the app pins several and falls through them.

Expected output is `12 checks: 12 pass` and `3 independent clients work`.

If the **player** stage fails across all clients, YouTube has rotated its accepted
versions. Update them in `MediaPlayerApp/MediaPlayerApp/YouTubeSource.swift`, in
the section marked `MAINTENANCE: client identities`, and the matching constants at
the top of both probe scripts:

```swift
ClientProfile(id: "ios", name: "IOS", version: "20.10.4", ...)
ClientProfile(id: "android_vr", name: "ANDROID_VR", version: "1.62.27", ...)
ClientProfile(id: "android", name: "ANDROID", version: "20.10.38", ...)
```

Current values can be cross-checked against what
[yt-dlp](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/_base.py)
uses, since it tracks the same clients. `probe-clients.py` also surfaces any
*other* identity that has started working, which can be promoted into the chain.

## Optional: Invidious fallback

Only useful if you self-host one, as a backup for when on-device extraction
breaks. See <https://docs.invidious.io/installation/>, then Settings →
**Invidious fallback** → enter the host → Save.

The client-side bugs that would have broken this even against a healthy server
are fixed: media is requested with `local=true` so your instance proxies it
(raw `googlevideo` URLs are IP-locked and 403 from the phone), audio tracks are
matched on `type.hasPrefix("audio/")` because the API returns full MIME types,
and the quality-selection expression has correct `&&`/`||` grouping.

## Project layout

```
media-app/
├── FINDINGS.md                     measurements behind the backend decision
├── DOCUMENTATION.md                architecture and internals
├── .github/workflows/ios-build.yml cloud macOS build -> unsigned .ipa
├── scripts/
│   ├── build-unsigned-ipa.sh       local build (macOS)
│   ├── generate-icons.ps1          regenerates app icons (Windows)
│   ├── validate-project.ps1        project.pbxproj integrity check
│   └── lint-swift.ps1              Swift structural checks
└── MediaPlayerApp/
    ├── MediaPlayerApp.xcodeproj/
    └── MediaPlayerApp/
        ├── MediaPlayerApp.swift        entry point
        ├── RootView.swift              tabs + mini player
        ├── BrowseView.swift            unified search
        ├── NowPlayingView.swift        player (audio + video)
        ├── QueueView.swift             up next
        ├── LibraryView.swift           favorites / recent / files
        ├── SettingsView.swift          source toggles
        ├── PlayerEngine.swift          AVPlayer, queue, modes
        ├── NowPlayingController.swift  lock screen + remote commands
        ├── VideoSurface.swift          AVPlayerLayer + PiP + AirPlay
        ├── MediaItem.swift             model
        ├── Library.swift               favorites/recents persistence
        ├── MediaSource.swift           source protocol + registry
        ├── YouTubeSource.swift         on-device InnerTube extraction
        ├── PodcastSource.swift
        ├── ArchiveSource.swift
        ├── LocalFilesSource.swift
        ├── InvidiousSource.swift
        ├── HTTPClient.swift
        └── Formatters.swift
```

## Checks you can run on Windows

```powershell
powershell -ExecutionPolicy Bypass -File scripts\validate-project.ps1
powershell -ExecutionPolicy Bypass -File scripts\lint-swift.ps1
python scripts\probe-youtube.py
python scripts\probe-clients.py
```

The first verifies the Xcode project's referential integrity — no duplicate
object IDs, no dangling references, every Swift file on disk present in the
Sources build phase, `Info.plist` not mis-filed as a bundle resource, declared
icon files actually present. The second checks delimiter balance, duplicate type
names, and dangling references to removed types.

Neither is a compiler. The build itself is verified by the GitHub Actions job.

## Limitations

| Limitation | Notes |
|---|---|
| YouTube extraction needs occasional upkeep | 3-client fallback softens it; see "When YouTube breaks" |
| Age-restricted videos | need a signed-in account; the app shows a clear reason |
| 7-day signing | free Apple ID; SideStore auto-refreshes |
| 3 devices, 10 App IDs | free Apple ID limits |
| Video image stops in background | iOS restriction; **audio keeps playing**, or use PiP to keep the picture |
| No offline download | streams only; import files for offline |
| Archive.org durations | unknown until playback starts, shown as `--:--` |
| No YouTube comments/playlists | search and playback only |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Untrusted Developer" | Settings → General → VPN & Device Management → trust your Apple ID |
| App won't install | enable Developer Mode and restart the iPhone |
| Search shows "Some sources didn't respond" | that backend is down; others still returned results |
| Nothing plays, all sources fail | check connectivity; Archive.org occasionally rate-limits |
| YouTube results appear but won't play | run `python scripts/probe-youtube.py`; likely a client-version rotation |
| A specific YouTube video won't play | age-restricted or region-blocked; the error names the reason |
| Ads appear in a YouTube video | switch on "Prefer progressive video" in Settings — trades 4K for a format that structurally can't carry them |
| Invidious source greyed out | expected — it's an optional fallback needing your own server |
| Audio stops when screen locks | `UIBackgroundModes` must contain `audio`; the CI job asserts this |
| App expired after a week | open SideStore → Refresh All |

## License

Personal use. Not for App Store distribution.

Podcast feeds and Internet Archive items are public resources meant for direct
access; respect individual item licenses. Local files are yours.
