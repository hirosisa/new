"""Live verification of YouTubeSource.filterMasterToAVC (YouTubeSource.swift).

    python scripts/verify-avc-filter.py [VIDEO_ID]

Fetches a real HLS master with the AppleCoreMedia UA (exactly what avcOnlyMaster
does), runs a line-for-line Python port of filterMasterToAVC + attribute(),
and asserts the expected rewrite:

  - every surviving #EXT-X-STREAM-INF variant is avc1 (no vp09, no av01)
  - the audio groups referenced by kept variants keep their TYPE=AUDIO lines
  - TYPE=SUBTITLES media lines are dropped
  - a playlist with nothing to keep is returned unchanged

The Swift logic this mirrors (do not let them drift):
  keep a STREAM-INF pair iff CODECS contains avc1 and not vp09/av01;
  collect the AUDIO group ids of kept variants; keep TYPE=AUDIO #EXT-X-MEDIA
  lines whose GROUP-ID is kept, drop TYPE=SUBTITLES, strip the SUBTITLES
  attribute from kept STREAM-INF lines, pass everything else.
"""

import argparse
import json
import re
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


# --- faithful port of YouTubeSource.attribute(named:in:) ---------------------

def attribute(line: str, name: str) -> str | None:
    marker = f"{name}="
    start = line.find(marker)
    if start == -1:
        return None
    rest = line[start + len(marker):]
    if rest.startswith('"'):
        end = rest.find('"', 1)
        if end == -1:
            return None
        return rest[1:end]
    # Unquoted: up to ',' (Swift also stops at '\r', impossible after split).
    end = len(rest)
    for i, ch in enumerate(rest):
        if ch == "," or ch == "\r":
            end = i
            break
    return rest[:end]


# --- faithful port of YouTubeSource.strippingSubtitlesAttribute(from:) --------

def strip_subtitles_attribute(line: str) -> str:
    # YouTube masters always quote the value; if one ever doesn't, the line is
    # passed through untouched rather than mangled.
    marker = ',SUBTITLES="'
    start = line.find(marker)
    if start == -1:
        return line
    rest = line[start + len(marker):]
    end = rest.find('"')
    if end == -1:
        return line
    return line[:start] + rest[end + 1:]


# --- faithful port of YouTubeSource.filterMasterToAVC ------------------------

def filter_master_to_avc(playlist: str) -> str:
    # split(whereSeparator: \.isNewline) — same separator set, empties dropped.
    lines = [l for l in re.split(r"[\r\n  ]", playlist) if l]
    kept_audio_groups: set[str] = set()
    keep_stream = [False] * len(lines)

    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("#EXT-X-STREAM-INF:"):
            codecs = (attribute(line, "CODECS") or "").lower()
            is_avc = "avc1" in codecs and "vp09" not in codecs and "av01" not in codecs
            keep_stream[index] = is_avc
            if index + 1 < len(lines):
                keep_stream[index + 1] = is_avc
            if is_avc:
                group = attribute(line, "AUDIO")
                if group is not None:
                    kept_audio_groups.add(group)
            index += 2
            continue
        index += 1

    if not kept_audio_groups and not any(keep_stream):
        return playlist

    output: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("#EXT-X-STREAM-INF:"):
            if keep_stream[index]:
                output.append(strip_subtitles_attribute(line))
                if index + 1 < len(lines):
                    output.append(lines[index + 1])
            index += 2
            continue
        if line.startswith("#EXT-X-MEDIA:"):
            media_type = attribute(line, "TYPE")
            if media_type == "AUDIO":
                group = attribute(line, "GROUP-ID")
                if group is not None and group in kept_audio_groups:
                    output.append(line)
                index += 1
                continue
            if media_type == "SUBTITLES":
                index += 1
                continue
        output.append(line)
        index += 1

    return "\n".join(output) + "\n"


# --- live fetch ---------------------------------------------------------------

def innertube_player(video_id: str) -> dict:
    payload = {
        "videoId": video_id,
        "contentCheckOk": True,
        "racyCheckOk": True,
        "context": {"client": PLAYER_CLIENT},
    }
    req = urllib.request.Request(
        f"{ENDPOINT}/player",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": PLAYER_UA,
            "Accept-Language": "en-US,en;q=0.9",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def fetch_master(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": COREMEDIA_UA})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.read().decode("utf-8")


def stream_inf_variants(playlist: str) -> list[tuple[str, str]]:
    """(header line, following URI line) pairs, as the Swift pair-scan sees them."""
    pairs: list[tuple[str, str]] = []
    lines = [l for l in re.split(r"[\r\n]", playlist) if l]
    i = 0
    while i < len(lines):
        if lines[i].startswith("#EXT-X-STREAM-INF:"):
            uri = lines[i + 1] if i + 1 < len(lines) else ""
            pairs.append((lines[i], uri))
            i += 2
        else:
            i += 1
    return pairs


def codes_of(header: str) -> list[str]:
    codecs = attribute(header, "CODECS") or ""
    return [c.strip() for c in codecs.lower().split(",") if c.strip()]


def count_by_codec(pairs):
    counts = {"vp09": 0, "avc1": 0, "av01": 0}
    for header, _ in pairs:
        codecs = codes_of(header)
        for key in counts:
            if any(c.startswith(key) for c in codecs):
                counts[key] += 1
                break
    return counts


def check(name: str, ok: bool, detail: str = "") -> bool:
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    return ok


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("video_id", nargs="?", default="dQw4w9WgXcQ")
    args = ap.parse_args()

    failures = 0
    print(f"Fetching player response (IOS client) for {args.video_id}")
    player = innertube_player(args.video_id)
    hls = (player.get("streamingData") or {}).get("hlsManifestUrl")
    if not hls:
        print("FAIL: no hlsManifestUrl in player response — cannot verify")
        sys.exit(1)

    print("Fetching HLS master with AppleCoreMedia UA")
    original = fetch_master(hls)

    orig_pairs = stream_inf_variants(original)
    orig_counts = count_by_codec(orig_pairs)
    print(f"Original master: {len(orig_pairs)} variants "
          f"({orig_counts['vp09']} vp09, {orig_counts['avc1']} avc1, {orig_counts['av01']} av01)")

    filtered = filter_master_to_avc(original)
    filt_pairs = stream_inf_variants(filtered)
    filt_counts = count_by_codec(filt_pairs)
    print(f"Filtered master: {len(filt_pairs)} variants "
          f"({filt_counts['vp09']} vp09, {filt_counts['avc1']} avc1, {filt_counts['av01']} av01)")

    print()
    failures += not check("original has variants", len(orig_pairs) > 0,
                          f"{len(orig_pairs)}")
    failures += not check("original matches measured shape (10 vp09 + 7 avc1 = 17)",
                          orig_counts == {"vp09": 10, "avc1": 7, "av01": 0}
                          and len(orig_pairs) == 17,
                          f"got {len(orig_pairs)} = {orig_counts['vp09']} vp09 "
                          f"+ {orig_counts['avc1']} avc1 + {orig_counts['av01']} av01")
    failures += not check("filtered keeps only avc1",
                          filt_counts["avc1"] == len(filt_pairs) and filt_counts["avc1"] > 0,
                          f"{filt_counts['avc1']}/{len(filt_pairs)}")
    failures += not check("filtered drops vp09", filt_counts["vp09"] == 0)
    failures += not check("filtered drops av01", filt_counts["av01"] == 0)
    failures += not check("filtered keeps all original avc1 variants",
                          filt_counts["avc1"] == orig_counts["avc1"])

    # Audio groups referenced by kept variants must survive as TYPE=AUDIO lines.
    wanted_groups = {attribute(h, "AUDIO") for h, _ in filt_pairs if attribute(h, "AUDIO")}
    media_audio = [l for l in filtered.splitlines()
                   if l.startswith("#EXT-X-MEDIA:") and attribute(l, "TYPE") == "AUDIO"]
    kept_groups = {attribute(l, "GROUP-ID") for l in media_audio}
    failures += not check("every kept AUDIO group has its media line",
                          wanted_groups <= kept_groups,
                          f"variants reference {sorted(wanted_groups)}, "
                          f"media lines keep {sorted(kept_groups)}")
    failures += not check("audio groups 233 and 234 kept",
                          {"233", "234"} <= kept_groups,
                          f"kept {sorted(kept_groups)}")

    # Subtitles dropped, no orphan audio media lines, URIs intact.
    failures += not check("no TYPE=SUBTITLES media lines remain",
                          not any(l.startswith("#EXT-X-MEDIA:")
                                  and attribute(l, "TYPE") == "SUBTITLES"
                                  for l in filtered.splitlines()))
    orig_groups = {attribute(h, "AUDIO") for h, _ in orig_pairs if attribute(h, "AUDIO")}
    failures += not check("no orphan AUDIO media lines (groups not referenced by kept variants)",
                          kept_groups <= wanted_groups,
                          f"extra groups: {sorted(kept_groups - wanted_groups)}")
    failures += not check("no kept variant references a SUBTITLES group (dropped renditions)",
                          all(attribute(h, "SUBTITLES") is None for h, _ in filt_pairs))
    failures += not check("every kept variant URI is a well-formed https URL",
                          all(u.startswith("https://") for _, u in filt_pairs))
    # The live master has no #EXT-X-VERSION — its header is #EXTM3U,
    # #EXT-X-INDEPENDENT-SEGMENTS, then the first #EXT-X-MEDIA. The filter must
    # pass those header lines through verbatim.
    header = original.splitlines()[:2]
    failures += not check("header lines survive verbatim (#EXTM3U, #EXT-X-INDEPENDENT-SEGMENTS)",
                          filtered.startswith("#EXTM3U")
                          and all(h in filtered for h in header))

    # Idempotence + degenerate-input behavior of the Swift code path.
    failures += not check("filter is idempotent", filter_master_to_avc(filtered) == filtered)
    # Degenerate case: strip STREAM-INF pairs and their https URIs.
    no_video = "\n".join(
        l for l in original.splitlines()
        if not l.startswith("#EXT-X-STREAM-INF") and not l.startswith("https://")) + "\n"
    failures += not check("playlist with no stream entries returned unchanged",
                          filter_master_to_avc(no_video) == no_video)

    print()
    if failures:
        print(f"{failures} check(s) FAILED")
        sys.exit(1)
    print("All checks passed.")


if __name__ == "__main__":
    main()
