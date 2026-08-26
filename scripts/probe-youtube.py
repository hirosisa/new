"""End-to-end check of the YouTube extraction pipeline the app uses.

    python scripts/probe-youtube.py [VIDEO_ID] [--query "search terms"]

Run this when playback stops working. It tests each stage independently so you
can see exactly which one broke, and it mirrors what YouTubeSource.swift does.
Whatever fails here will fail in the app for the same reason.

Stages:
  1. Search  (WEB client)   -> videoRenderer objects with title/duration/channel
  2. Player  (IOS client)   -> direct stream URLs, no cipher, no PO token
  3. Fetch   (AppleCoreMedia UA) -> what AVPlayer itself sends
  4. Ads                    -> adPlacements and HLS splice markers

If stage 2 fails, the usual fix is bumping the client versions below and in
MediaPlayerApp/MediaPlayerApp/YouTubeSource.swift (enum Client).
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

# Keep in sync with YouTubeSource.swift -> enum Client
SEARCH_CLIENT = {
    "clientName": "WEB",
    "clientVersion": "2.20250312.04.00",
    "hl": "en",
    "gl": "US",
}
SEARCH_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36")

PLAYER_CLIENT = {
    "clientName": "IOS",
    "clientVersion": "20.10.4",
    "deviceMake": "Apple",
    "deviceModel": "iPhone16,2",
    "osName": "iPhone",
    "osVersion": "18.3.2.22D82",
    "hl": "en",
    "gl": "US",
}
PLAYER_UA = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)"

# What AVPlayer actually sends when it streams.
COREMEDIA_UA = "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)"

VIDEO_ONLY_PARAMS = "EgIQAQ%3D%3D"
ENDPOINT = "https://www.youtube.com/youtubei/v1"

PASS, FAIL, WARN = "PASS", "FAIL", "WARN"
results = []


def report(stage, status, detail=""):
    results.append((stage, status))
    print(f"  [{status}] {stage}" + (f" — {detail}" if detail else ""))


def innertube(path, payload, ua):
    req = urllib.request.Request(
        f"{ENDPOINT}/{path}",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": ua,
            "Accept-Language": "en-US,en;q=0.9",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        ctype = resp.headers.get("Content-Type", "")
        raw = resp.read()
        if "html" in ctype.lower():
            raise RuntimeError(f"got HTML instead of JSON (content-type {ctype})")
        return json.loads(raw.decode())


def collect(node, keys, out):
    if isinstance(node, dict):
        for k in keys:
            if isinstance(node.get(k), dict):
                out.append(node[k])
        for v in node.values():
            collect(v, keys, out)
    elif isinstance(node, list):
        for v in node:
            collect(v, keys, out)


def text_of(node):
    if not isinstance(node, dict):
        return None
    if node.get("simpleText"):
        return node["simpleText"]
    runs = node.get("runs")
    if isinstance(runs, list):
        joined = "".join(r.get("text", "") for r in runs)
        return joined or None
    return None


def fetch(url, ua, ranged=True, label=""):
    headers = {"User-Agent": ua}
    if ranged:
        headers["Range"] = "bytes=0-2047"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
            return True, f"HTTP {r.status}, {len(body)} bytes, {r.headers.get('Content-Type')}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code} {e.reason}"
    except Exception as e:  # noqa: BLE001
        return False, f"{type(e).__name__}: {e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video_id", nargs="?", default="dQw4w9WgXcQ")
    ap.add_argument("--query", default="lofi hip hop")
    args = ap.parse_args()

    print("=" * 70)
    print("STAGE 1 — Search (WEB client)")
    try:
        data = innertube("search", {
            "query": args.query,
            "params": VIDEO_ONLY_PARAMS,
            "context": {"client": SEARCH_CLIENT},
        }, SEARCH_UA)

        hits = []
        collect(data, ["videoRenderer", "compactVideoRenderer"], hits)
        parseable = [h for h in hits if h.get("videoId")]

        if not parseable:
            report("search returns results", FAIL,
                   "no videoRenderer nodes — response shape changed")
        else:
            report("search returns results", PASS, f"{len(parseable)} videos")
            sample = parseable[0]
            title = text_of(sample.get("title"))
            length = text_of(sample.get("lengthText"))
            owner = (text_of(sample.get("ownerText"))
                     or text_of(sample.get("longBylineText")))
            missing = [n for n, v in
                       (("title", title), ("channel", owner)) if not v]
            if missing:
                report("search metadata complete", WARN,
                       f"missing {', '.join(missing)}")
            else:
                report("search metadata complete", PASS,
                       f"{owner} — {str(title)[:40]} [{length or 'live'}]")
    except Exception as e:  # noqa: BLE001
        report("search returns results", FAIL, str(e))

    print()
    print(f"STAGE 2 — Player (IOS client), video {args.video_id}")
    player = None
    try:
        player = innertube("player", {
            "videoId": args.video_id,
            "contentCheckOk": True,
            "racyCheckOk": True,
            "context": {"client": PLAYER_CLIENT},
        }, PLAYER_UA)

        status = (player.get("playabilityStatus") or {}).get("status")
        reason = (player.get("playabilityStatus") or {}).get("reason") or ""
        if status == "OK":
            report("playabilityStatus OK", PASS)
        else:
            report("playabilityStatus OK", FAIL, f"{status} {reason}")

        streaming = player.get("streamingData") or {}
        adaptive = streaming.get("adaptiveFormats") or []
        muxed = streaming.get("formats") or []
        allf = adaptive + muxed

        ciphered = [f for f in allf if not f.get("url")]
        if allf and not ciphered:
            report("URLs are un-ciphered", PASS,
                   f"{len(allf)} formats, none need JS deciphering")
        elif ciphered:
            report("URLs are un-ciphered", FAIL,
                   f"{len(ciphered)}/{len(allf)} need signature deciphering")
        else:
            report("URLs are un-ciphered", FAIL, "no formats returned")

        audio = [f for f in adaptive
                 if (f.get("mimeType") or "").startswith("audio/mp4") and f.get("url")]
        if audio:
            best = max(audio, key=lambda f: f.get("bitrate", 0))
            report("m4a audio track present", PASS,
                   f"itag {best.get('itag')}, {best.get('bitrate')} bps")
        else:
            report("m4a audio track present", FAIL, "audio-only mode would break")

        if streaming.get("hlsManifestUrl"):
            report("HLS manifest present", PASS)
        else:
            report("HLS manifest present", WARN,
                   "video falls back to muxed progressive (lower quality)")
    except Exception as e:  # noqa: BLE001
        report("player request", FAIL, str(e))

    print()
    print("STAGE 3 — Stream fetch using AVPlayer's own User-Agent")
    if player:
        streaming = player.get("streamingData") or {}
        adaptive = streaming.get("adaptiveFormats") or []

        audio = [f for f in adaptive
                 if (f.get("mimeType") or "").startswith("audio/mp4") and f.get("url")]
        if audio:
            best = max(audio, key=lambda f: f.get("bitrate", 0))
            ok, detail = fetch(best["url"], COREMEDIA_UA)
            report("audio stream fetchable", PASS if ok else FAIL, detail)

        hls = streaming.get("hlsManifestUrl")
        if hls:
            ok, detail = fetch(hls, COREMEDIA_UA, ranged=False)
            report("HLS master fetchable", PASS if ok else FAIL, detail)

            if ok:
                try:
                    req = urllib.request.Request(hls, headers={"User-Agent": COREMEDIA_UA})
                    text = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
                    res = sorted({r for r in re.findall(r"RESOLUTION=(\d+x\d+)", text)},
                                 key=lambda s: int(s.split("x")[1]))
                    report("HLS variants", PASS,
                           f"{len(res)} renditions, max {res[-1] if res else '?'}")

                    media = re.search(r"^(https://\S+)$", text, re.M)
                    if media:
                        ok2, detail2 = fetch(media.group(1), COREMEDIA_UA, ranged=False)
                        report("HLS media playlist fetchable", PASS if ok2 else FAIL, detail2)
                except Exception as e:  # noqa: BLE001
                    report("HLS variants", WARN, str(e))
    else:
        report("stream fetch", FAIL, "skipped, stage 2 failed")

    print()
    print("STAGE 4 — Ad presence")
    if player:
        placements = player.get("adPlacements") or []
        if placements:
            report("no adPlacements", WARN, f"{len(placements)} present in response")
        else:
            report("no adPlacements", PASS, "player response advertises no ads")

        streaming = player.get("streamingData") or {}
        hls = streaming.get("hlsManifestUrl")
        if hls:
            try:
                req = urllib.request.Request(hls, headers={"User-Agent": COREMEDIA_UA})
                text = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
                media = re.search(r"^(https://\S+)$", text, re.M)
                combined = text
                if media:
                    req2 = urllib.request.Request(media.group(1), headers={"User-Agent": COREMEDIA_UA})
                    combined += urllib.request.urlopen(req2, timeout=30).read().decode("utf-8", "replace")

                markers = [m for m in ("EXT-X-DATERANGE", "EXT-X-CUE-OUT", "SCTE35",
                                       "EXT-X-ASSET", "EXT-X-SPLICEPOINT")
                           if m in combined]
                if markers:
                    report("no HLS ad markers", WARN,
                           f"found {markers} — enable 'prefer progressive' in Settings")
                else:
                    report("no HLS ad markers", PASS, "no server-side ad insertion")
            except Exception as e:  # noqa: BLE001
                report("no HLS ad markers", WARN, str(e))
    else:
        report("ad presence", FAIL, "skipped, stage 2 failed")

    print()
    print("=" * 70)
    failed = [s for s, st in results if st == FAIL]
    warned = [s for s, st in results if st == WARN]
    print(f"{len(results)} checks: "
          f"{len(results) - len(failed) - len(warned)} pass, "
          f"{len(warned)} warn, {len(failed)} fail")
    if failed:
        print("\nFAILED:")
        for s in failed:
            print(f"  - {s}")
        print("\nIf the player stage failed, bump the client versions in this file")
        print("and in YouTubeSource.swift (enum Client), then re-run.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
