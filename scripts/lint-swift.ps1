# Static sanity checks for the Swift sources, runnable without a Mac.
#
#   powershell -ExecutionPolicy Bypass -File scripts\lint-swift.ps1
#
# This is NOT a compiler. It catches the mechanical mistakes that are easy to
# make when editing Swift without a toolchain: unbalanced delimiters, duplicate
# top-level type names, dangling references to deleted types, SwiftUI views with
# no body, and force-unwraps inside view bodies (the crash that shipped in the
# previous MiniPlayer).

$ErrorActionPreference = 'Stop'

$root      = Resolve-Path (Join-Path $PSScriptRoot '..')
$sourceDir = Join-Path $root 'MediaPlayerApp\MediaPlayerApp'
$files     = Get-ChildItem $sourceDir -Filter *.swift | Sort-Object Name

$errors   = @()
$warnings = @()

# Types that were removed in the rewrite. Any surviving reference is a bug.
$deletedSymbols = @(
    'AudioManager', 'FavoritesManager', 'YouTubeService', 'ContentView',
    'PlaybackMode', 'SearchViewModel', 'MusicPlayerView', 'VideoPlayerView',
    'FavoritesView', 'SearchView', 'VideoPlayerContainer', 'VideoPlayerViewRepresentable'
)

$declaredTypes = @{}

function Strip-Noise([string]$text) {
    # Order matters. String literals must go before line comments, otherwise the
    # "//" inside a URL such as "https://archive.org" is mistaken for a comment
    # and the rest of the line — including its closing brackets — is discarded.
    $t = [regex]::Replace($text, '(?s)/\*.*?\*/', '')          # block comments
    $t = [regex]::Replace($t, '(?s)""".*?"""', '""')            # multiline strings
    $t = [regex]::Replace($t, '"(?:[^"\\\r\n]|\\.)*"', '""')    # normal strings
    $t = [regex]::Replace($t, '(?m)//.*$', '')                  # line comments
    return $t
}

foreach ($f in $files) {
    $raw = Get-Content $f.FullName -Raw
    $code = Strip-Noise $raw
    $name = $f.Name

    # --- delimiter balance ---
    foreach ($pair in @(@('{','}'), @('(',')'), @('[',']'))) {
        $open  = ([regex]::Matches($code, [regex]::Escape($pair[0]))).Count
        $close = ([regex]::Matches($code, [regex]::Escape($pair[1]))).Count
        if ($open -ne $close) {
            $errors += "$name : unbalanced '$($pair[0])$($pair[1])' -> $open open vs $close close"
        }
    }

    # --- references to deleted types ---
    foreach ($sym in $deletedSymbols) {
        if ([regex]::IsMatch($code, "\b$sym\b")) {
            $errors += "$name : references removed type '$sym'"
        }
    }

    # --- top-level type declarations, for duplicate detection ---
    # Anchored at column zero on purpose: indented declarations are nested types
    # (e.g. PlayerResponse.Format vs VideoDetail.Format) and do not collide.
    foreach ($m in [regex]::Matches($code, '(?m)^(?:public\s+|private\s+|internal\s+|fileprivate\s+)?(?:final\s+)?(?:@\w+\s+)*(?:struct|class|enum|actor|protocol)\s+([A-Za-z_]\w*)')) {
        $typeName = $m.Groups[1].Value
        $isPrivate = $m.Value -match '\b(private|fileprivate)\b'
        $key = $typeName
        if ($declaredTypes.ContainsKey($key)) {
            # Two file-private types may share a name legitimately.
            if (-not $isPrivate -and -not $declaredTypes[$key].Private) {
                $errors += "$name : duplicate top-level type '$typeName' (also in $($declaredTypes[$key].File))"
            }
        } else {
            $declaredTypes[$key] = [pscustomobject]@{ File = $name; Private = $isPrivate }
        }
    }

    # --- SwiftUI views must have a body ---
    foreach ($m in [regex]::Matches($code, '(?m)^(?:private\s+)?struct\s+([A-Za-z_]\w*)\s*:\s*(?:[^\{]*\b)?View\b')) {
        $viewName = $m.Groups[1].Value
        if ($code -notmatch 'var\s+body\s*:') {
            $errors += "$name : view '$viewName' has no 'body'"
        }
    }

    # --- force unwraps / force casts in declarative UI ---
    # `layer as! AVPlayerLayer` in VideoSurface is deliberate and correct.
    $forceMatches = [regex]::Matches($code, '(?m)^(.*?[A-Za-z_\)\]]!(?!=)\s*[\).,\s\{].*)$')
    foreach ($fm in $forceMatches) {
        $line = $fm.Groups[1].Value.Trim()
        if ($line -match 'as!\s*AVPlayerLayer') { continue }
        if ($line -match '^\s*(import|@|//)') { continue }
        # `try!` and `x!` inside a body are what we care about.
        if ($line -match '\b(try!|as!)\b' -or $line -match '[A-Za-z_\)\]]!\s*[\).,]') {
            $warnings += "$name : possible force unwrap -> $line"
        }
    }

    # --- leftover editing artefacts ---
    foreach ($marker in @('<<<<<<<', '>>>>>>>', 'TODO:', 'FIXME:')) {
        if ($code -match [regex]::Escape($marker)) {
            $warnings += "$name : contains '$marker'"
        }
    }
}

# --- entry point sanity ---
$mainCount = 0
foreach ($f in $files) {
    if ((Get-Content $f.FullName -Raw) -match '(?m)^\s*@main\b') { $mainCount++ }
}
if ($mainCount -ne 1) { $errors += "Expected exactly one @main entry point, found $mainCount" }

# --- every MediaSource implementation must be in the registry ---
$registry = Get-Content (Join-Path $sourceDir 'MediaSource.swift') -Raw
foreach ($impl in @('PodcastSource', 'ArchiveSource', 'LocalFilesSource', 'InvidiousSource')) {
    if ($registry -notmatch [regex]::Escape($impl)) {
        $errors += "MediaSource.swift : $impl is not wired into SourceRegistry"
    }
}

# --- report ---
Write-Output "Swift files checked: $($files.Count)"
Write-Output "Top-level types found: $($declaredTypes.Count)"

if ($warnings.Count -gt 0) {
    Write-Output ''
    Write-Output "WARNINGS ($($warnings.Count)):"
    $warnings | ForEach-Object { Write-Output "  - $_" }
}

Write-Output ''
if ($errors.Count -eq 0) {
    Write-Output 'PASS: no structural problems found.'
    exit 0
} else {
    Write-Output "FAIL: $($errors.Count) problem(s):"
    $errors | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
