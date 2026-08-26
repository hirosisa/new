"""Survey which InnerTube client identities can still fetch streams.

    python scripts/probe-clients.py [VIDEO_ID]

The point is resilience. A single client is a single point of failure; a ranked
fallback chain means YouTube has to close several doors at once before playback
breaks. This measures which doors are currently open so the chain in
YouTubeSource.swift is based on evidence rather than folklore.
"""

import json
import sys
import urllib.error
import urllib.request

VIDEO_ID = sys.argv[1] if len(sys.argv) > 1 else "dQw4w9WgXcQ"
ENDPOINT = "https://www.youtube.com/youtubei/v1/player"
COREMEDIA_UA = "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)"

# name -> (context client dict, User-Agent)
CLIENTS = {
    "IOS": ({
        "clientName": "IOS", "clientVersion": "20.10.4",
        "deviceMake": "Apple", "deviceModel": "iPhone16,2",
        "osName": "iPhone", "osVersion": "18.3.2.22D82",
        "hl": "en", "gl": "US",
    }, "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)"),

    "IOS_MUSIC": ({
        "clientName": "IOS_MUSIC", "clientVersion": "7.31.2",
        "deviceMake": "Apple", "deviceModel": "iPhone16,2",
        "osName": "iPhone", "osVersion": "18.3.2.22D82",
        "hl": "en", "gl": "US",
    }, "com.google.ios.youtubemusic/7.31.2 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)"),

    "ANDROID_VR": ({
        "clientName": "ANDROID_VR", "clientVersion": "1.62.27",
        "deviceMake": "Oculus", "deviceModel": "Quest 3",
        "osName": "Android", "osVersion": "12", "androidSdkVersion": 32,
        "hl": "en", "gl": "US",
    }, "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12; en_US)"),

    "TVHTML5": ({
        "clientName": "TVHTML5", "clientVersion": "7.20250312.16.00",
        "hl": "en", "gl": "US",
    }, "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"),

    "TVHTML5_SIMPLY_EMBEDDED_PLAYER": ({
        "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER", "clientVersion": "2.0",
        "hl": "en", "gl": "US",
    }, "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"),

    "MWEB": ({
        "clientName": "MWEB", "clientVersion": "2.20250312.04.00",
        "hl": "en", "gl": "US",
    }, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3_2 like Mac OS X) AppleWebKit/605.1.15 "
       "(KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"),

    "WEB_EMBEDDED_PLAYER": ({
        "clientName": "WEB_EMBEDDED_PLAYER", "clientVersion": "1.20250312.01.00",
        "hl": "en", "gl": "US",
    }, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"),

    "ANDROID": ({
        "clientName": "ANDROID", "clientVersion": "20.10.38",
        "deviceMake": "Google", "deviceModel": "Pixel 9",
        "osName": "Android", "osVersion": "15", "androidSdkVersion": 35,
        "hl": "en", "gl": "US",
    }, "com.google.android.youtube/20.10.38 (Linux; U; Android 15; en_US) gzip"),

    "WEB": ({
        "clientName": "WEB", "clientVersion": "2.20250312.04.00",
        "hl": "en", "gl": "US",
    }, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"),
}


def player(client, ua):
    payload = {
        "videoId": VIDEO_ID,
        "contentCheckOk": True,
        "racyCheckOk": True,
        "context": {"client": client},
    }
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": ua,
            "Accept-Language": "en-US,en;q=0.9",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def can_fetch(url, ranged=True):
    headers = {"User-Agent": COREMEDIA_UA}
    if ranged:
        headers["Range"] = "bytes=0-1023"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, headers=headers), timeout=25
        ) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:  # noqa: BLE001
        return None


print(f"video: {VIDEO_ID}")
print()
header = f"{'CLIENT':<32}{'STATUS':<10}{'AUDIO':<8}{'MUXED':<8}{'HLS':<6}{'CIPHER':<8}FETCH"
print(header)
print("-" * len(header))

usable = []

for name, (client, ua) in CLIENTS.items():
    try:
        d = player(client, ua)
    except Exception as e:  # noqa: BLE001
        print(f"{name:<32}{'REQ FAIL':<10}{str(e)[:34]}")
        continue

    status = (d.get("playabilityStatus") or {}).get("status") or "?"
    sd = d.get("streamingData") or {}
    adaptive = sd.get("adaptiveFormats") or []
    muxed = sd.get("formats") or []

    audio = [f for f in adaptive
             if (f.get("mimeType") or "").startswith("audio/mp4") and f.get("url")]
    muxed_ok = [f for f in muxed if f.get("url")]
    hls = bool(sd.get("hlsManifestUrl"))
    ciphered = len([f for f in (adaptive + muxed) if not f.get("url")])

    fetch = "-"
    if audio:
        best = max(audio, key=lambda f: f.get("bitrate", 0))
        code = can_fetch(best["url"])
        fetch = f"audio {code}"
        if code == 206:
            usable.append(name)
    elif hls:
        code = can_fetch(sd["hlsManifestUrl"], ranged=False)
        fetch = f"hls {code}"
        if code == 200:
            usable.append(name)

    print(f"{name:<32}{status:<10}{len(audio):<8}{len(muxed_ok):<8}"
          f"{('yes' if hls else 'no'):<6}{ciphered:<8}{fetch}")

print()
print(f"clients that produced a playable stream: {len(usable)}")
for name in usable:
    print(f"  - {name}")
print()
if len(usable) == 0:
    print("Nothing works. Update the version strings above and in YouTubeSource.swift")
    print("(section 'MAINTENANCE: client identities'), cross-checking against yt-dlp.")
    sys.exit(1)
elif len(usable) == 1:
    print("Only one client works — no redundancy left. Worth refreshing the version")
    print("strings in YouTubeSource.swift before the last one closes too.")
else:
    print(f"{len(usable)} independent clients work, so YouTube would have to close")
    print("several doors at once to break playback. Keep playerClients in")
    print("YouTubeSource.swift ('MAINTENANCE: client identities') in sync with this.")
sys.exit(0)
