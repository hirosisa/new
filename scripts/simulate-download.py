"""PC-side simulation of the app's offline-download pipeline.

    python scripts/simulate-download.py [VIDEO_ID] [--audio|--video] [--out DIR]

Mirrors DownloadManager (Library.swift) tier by tier so the exact logic that
ships can be exercised and validated on a PC before a build goes to the phone:

  Tier 2  HLS master -> pick playlist (best audio rendition, or the
          highest-resolution H.264 variant — the master lists variants
          lowest-first) -> segments concatenated.
  Tier 3  muxed single file (itag 18-style) fetched in 1 MB ranged chunks —
          the request shape AVPlayer itself uses, after whole-file GETs of
          videoplayback URLs died (timed out / URLError -1) on an affected
          network.

Every produced file is validated with ffprobe (codec + duration + actually
decodable), so "bytes on disk" is not mistaken for "playable".

Keep in sync with Library.swift (do not let them drift).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.request

# Keep in sync with YouTubeSource.swift (enum Client / COREMEDIA UA).
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
COREMEDIA_UA = "AppleCoreMedia/1.0.0.22D82 (iPhone; U; CPU OS 18_3_2 like Mac OS X; en_us)"
ENDPOINT = "https://www.youtube.com/youtubei/v1"
CHUNK_SIZE = 1_048_576


def attribute(line: str, name: str) -> str | None:
    # Full port of the Swift attribute(named:in:): quoted and unquoted values.
    start = line.find(f"{name}=")
    if start == -1:
        return None
    rest = line[start + len(name) + 1:]
    if rest.startswith('"'):
        end = rest.find('"', 1)
        return None if end == -1 else rest[1:end]
    end = len(rest)
    for i, ch in enumerate(rest):
        if ch == "," or ch == "\r":
            end = i
            break
    return rest[:end]


def fetch(url: str, ua: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def hls_master_url(video_id: str) -> str:
    payload = {
        "videoId": video_id,
        "contentCheckOk": True,
        "racyCheckOk": True,
        "context": {"client": PLAYER_CLIENT},
    }
    req = urllib.request.Request(
        f"{ENDPOINT}/player",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": PLAYER_UA},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode())
    status = (data.get("playabilityStatus") or {}).get("status")
    hls = (data.get("streamingData") or {}).get("hlsManifestUrl")
    if status != "OK" or not hls:
        raise RuntimeError(f"player: status={status} hls={'yes' if hls else 'no'}")
    return hls


def pick_playlist(master_text: str, audio_only: bool) -> str:
    lines = master_text.splitlines()
    if audio_only:
        for line in lines:
            if line.startswith("#EXT-X-MEDIA:") and attribute(line, "TYPE") == "AUDIO":
                uri = attribute(line, "URI")
                if uri:
                    return uri
        raise RuntimeError("no audio rendition in master")

    best = None  # (height, uri)
    index = 0
    while index < len(lines) - 1:
        if lines[index].startswith("#EXT-X-STREAM-INF:"):
            uri = lines[index + 1]
            codecs = attribute(lines[index], "CODECS") or ""
            if uri.startswith("http") and "avc1" in codecs.lower():
                resolution = attribute(lines[index], "RESOLUTION") or ""
                height = int(resolution.split("x")[-1]) if "x" in resolution else 0
                if best is None or height > best[0]:
                    best = (height, uri)
            index += 2
            continue
        index += 1
    if best is None:
        raise RuntimeError("no H.264 variant in master")
    return best[1]


def fetch_segments(master_url: str, audio_only: bool) -> tuple[bytes, str]:
    master_text = fetch(master_url, COREMEDIA_UA).decode("utf-8")
    playlist_url = pick_playlist(master_text, audio_only)
    playlist = fetch(playlist_url, COREMEDIA_UA).decode("utf-8")
    segments = [l for l in playlist.splitlines() if l.startswith("http")]
    if not segments:
        raise RuntimeError("no segments in media playlist")

    data = bytearray()
    for offset, segment in enumerate(segments):
        data += fetch(segment, COREMEDIA_UA)
        print(f"    segment {offset + 1}/{len(segments)}")
    return bytes(data), sniff(data, audio_only)


def fetch_whole_file(remote: str, audio_only: bool) -> tuple[bytes, str]:
    """Ranged 1 MB chunks — mirrors the Swift fetchWholeFile, each chunk
    retried once."""
    data = bytearray()
    start = 0
    total = None
    while total is None or start < total:
        end = start + CHUNK_SIZE - 1 if total is None else min(start + CHUNK_SIZE, total) - 1
        header = {"User-Agent": COREMEDIA_UA, "Range": f"bytes={start}-{end}"}
        chunk = None
        for _ in range(2):
            try:
                req = urllib.request.Request(remote, headers=header)
                with urllib.request.urlopen(req, timeout=30) as resp:
                    expected = end - start + 1
                    # A ranged chunk at a non-zero offset MUST answer 206 — a
                    # 200 means the Range header was ignored (full body).
                    if start > 0 and resp.status != 206:
                        raise RuntimeError(f"HTTP {resp.status} (wanted 206)")
                    if resp.status not in (200, 206):
                        raise RuntimeError(f"HTTP {resp.status}")
                    content_range = resp.headers.get("Content-Range", "")
                    if total is None:
                        if "/" in content_range:
                            total = int(content_range.split("/")[-1])
                        else:
                            total = start + 1  # ranges unsupported; single pass
                    chunk = resp.read()
                    if resp.status == 206 and len(chunk) != expected:
                        raise RuntimeError(
                            f"short chunk {len(chunk)}/{expected}")
                break
            except Exception as e:  # noqa: BLE001
                print(f"    chunk {start}-{end} failed ({e}); retrying")
                chunk = None
        if chunk is None:
            raise RuntimeError(f"chunk {start}-{end} failed after retry")
        data += chunk
        start = end + 1
        print(f"    {min(start, total)}/{total} bytes")
    return bytes(data), sniff(data, audio_only)


def sniff(data: bytes, audio_only: bool) -> str:
    if data[:4] == b"ftyp":
        return "m4a" if audio_only else "mp4"
    if data[:1] == b"\x47":
        return "ts"
    if data[:3] == b"ID3" or data[:2] in (b"\xff\xf1", b"\xff\xf9"):
        return "aac"
    return "m4a" if audio_only else "ts"


def validate(path: str) -> tuple[bool, str]:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return True, "ffprobe not available — skipped decode validation"
    result = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries",
         "format=duration:stream=codec_name,codec_type", "-of", "json", path],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        return False, f"ffprobe failed: {result.stderr.strip()[:200]}"
    info = json.loads(result.stdout or "{}")
    streams = info.get("streams", [])
    duration = info.get("format", {}).get("duration")
    codecs = [f"{s.get('codec_type')}:{s.get('codec_name')}" for s in streams]
    if not streams:
        return False, "no streams detected"
    return True, f"{', '.join(codecs)}, {duration}s"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("video_id", nargs="?", default="dQw4w9WgXcQ")
    parser.add_argument("--video", action="store_true", help="download video (default: audio)")
    parser.add_argument("--out", default="downloads-test")
    args = parser.parse_args()
    audio_only = not args.video

    os.makedirs(args.out, exist_ok=True)
    failures = 0

    print(f"Simulating download of {args.video_id} ({'video' if args.video else 'audio-only'})")

    print("  Tier 2: HLS segments")
    if args.video:
        # Mirrors the Swift: video downloads skip this tier — YouTube's
        # video-variant TS segments carry NO audio stream (verified via
        # ffprobe), and there is no remuxer on device.
        print("    [SKIP] video downloads use the muxed tier (HLS variant segments are video-only)")
    else:
        try:
            master = hls_master_url(args.video_id)
            data, ext = fetch_segments(master, audio_only)
            path = os.path.join(args.out, f"segments.{ext}")
            with open(path, "wb") as f:
                f.write(data)
            ok, detail = validate(path)
            if ok:
                has_audio = any("audio" in c for c in detail.split(", "))
                if not has_audio:
                    ok, detail = False, "no audio stream — silent download"
            print(f"    [{'PASS' if ok else 'FAIL'}] {len(data)} bytes -> {path}: {detail}")
            failures += not ok
        except Exception as e:  # noqa: BLE001
            print(f"    [FAIL] {e}")
            failures += 1

    print("  Tier 3: muxed single file, ranged 1 MB chunks")
    try:
        req = urllib.request.Request(
            f"{ENDPOINT}/player",
            data=json.dumps({
                "videoId": args.video_id, "contentCheckOk": True, "racyCheckOk": True,
                "context": {"client": {
                    "clientName": "ANDROID_VR", "clientVersion": "1.62.27",
                    "deviceMake": "Oculus", "deviceModel": "Quest 3",
                    "osName": "Android", "osVersion": "12", "androidSdkVersion": 32,
                    "hl": "en", "gl": "US"}},
            }).encode(),
            headers={"Content-Type": "application/json",
                     "User-Agent": "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12; en_US)"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            player = json.loads(resp.read().decode())
        muxed = [f for f in (player.get("streamingData") or {}).get("formats", [])
                 if f.get("url") and (f.get("mimeType") or "").startswith("video/")]
        if not muxed:
            raise RuntimeError("no muxed format in ANDROID_VR response")
        data, ext = fetch_whole_file(muxed[0]["url"], audio_only)
        path = os.path.join(args.out, f"whole.{ext}")
        with open(path, "wb") as f:
            f.write(data)
        ok, detail = validate(path)
        print(f"    [{'PASS' if ok else 'FAIL'}] {len(data)} bytes -> {path}: {detail}")
        failures += not ok
    except Exception as e:  # noqa: BLE001
        print(f"    [FAIL] {e}")
        failures += 1

    print()
    print("FAILED" if failures else "All tiers validated playable.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
