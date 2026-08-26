"""Find which iOS client versions still return usable stream formats.

    python scripts/probe-versions.py

Run this when audio-only playback stops working, or before changing any version
string in YouTubeSource.swift.

Why this exists: newer is not better. Measured on 2026-08-26, the then-current
App Store version (21.34.3) returned `playabilityStatus: OK` and a working HLS
manifest but **zero** progressive audio formats — so video played fine and
audio-only mode silently broke. Versions 20.03.02 through 21.10.1 returned two
audio formats each. Blindly tracking the latest release is therefore a
regression, which is why the app pins a list of verified-good versions and falls
through them instead of auto-updating.

Anything reported GOOD here is a safe candidate for the playerClients chain.
"""

import json
import sys
import urllib.error
import urllib.request

# Spread across releases. Add newer ones as they ship to see if audio returns.
CANDIDATES = [
    "20.03.02",
    "20.10.4",
    "20.30.2",
    "21.10.1",
    "21.34.3",
]

COREMEDIA_UA = "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)"
TEST_VIDEO = sys.argv[1] if len(sys.argv) > 1 else "dQw4w9WgXcQ"


def current_app_store_version():
    """544007664 = YouTube on the App Store."""
    try:
        req = urllib.request.Request(
            "https://itunes.apple.com/lookup?id=544007664&country=us",
            headers={"User-Agent": "probe/1.0"},
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read().decode())
        if d.get("resultCount"):
            return d["results"][0].get("version")
    except Exception:  # noqa: BLE001
        pass
    return None


def player(version):
    client = {
        "clientName": "IOS", "clientVersion": version,
        "deviceMake": "Apple", "deviceModel": "iPhone16,2",
        "osName": "iPhone", "osVersion": "18.3.2.22D82",
        "hl": "en", "gl": "US",
    }
    ua = f"com.google.ios.youtube/{version} (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)"
    req = urllib.request.Request(
        "https://www.youtube.com/youtubei/v1/player",
        data=json.dumps({
            "videoId": TEST_VIDEO, "contentCheckOk": True, "racyCheckOk": True,
            "context": {"client": client},
        }).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": ua},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def fetchable(url):
    try:
        req = urllib.request.Request(
            url, headers={"Range": "bytes=0-1023", "User-Agent": COREMEDIA_UA})
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:  # noqa: BLE001
        return None


store = current_app_store_version()
print(f"current App Store version: {store or 'unknown'}")
if store and store not in CANDIDATES:
    print(f"  (not in the candidate list — appending it)")
    CANDIDATES.append(store)
print(f"test video: {TEST_VIDEO}")
print()

hdr = f"{'VERSION':<12}{'STATUS':<10}{'AUDIO':<7}{'HLS':<6}{'FETCH':<12}VERDICT"
print(hdr)
print("-" * len(hdr))

good = []

for version in CANDIDATES:
    try:
        d = player(version)
    except urllib.error.HTTPError as e:
        print(f"{version:<12}{'HTTP ' + str(e.code):<10}{'-':<7}{'-':<6}{'-':<12}REJECTED")
        continue
    except Exception as e:  # noqa: BLE001
        print(f"{version:<12}{'ERROR':<10}{str(e)[:40]}")
        continue

    status = (d.get("playabilityStatus") or {}).get("status") or "?"
    sd = d.get("streamingData") or {}
    audio = [f for f in (sd.get("adaptiveFormats") or [])
             if (f.get("mimeType") or "").startswith("audio/mp4") and f.get("url")]
    hls = bool(sd.get("hlsManifestUrl"))

    code = None
    if audio:
        best = max(audio, key=lambda f: f.get("bitrate", 0))
        code = fetchable(best["url"])

    if status == "OK" and audio and code == 206:
        verdict = "GOOD"
        good.append(version)
    elif status == "OK" and hls:
        verdict = "VIDEO ONLY (no audio-only)"
    else:
        verdict = "UNUSABLE"

    print(f"{version:<12}{status:<10}{len(audio):<7}{('yes' if hls else 'no'):<6}"
          f"{str(code or '-'):<12}{verdict}")

print()
if good:
    print(f"{len(good)} version(s) support audio-only playback:")
    for v in good:
        print(f"  - {v}")
    print()
    print("These are safe for the IOS entries in playerClients")
    print("(YouTubeSource.swift, 'MAINTENANCE: client identities').")
    sys.exit(0)
else:
    print("No version returned progressive audio. Audio-only mode cannot work until")
    print("one does — video via HLS may still be fine. Try adding newer versions above.")
    sys.exit(1)
