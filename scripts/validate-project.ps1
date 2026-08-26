# Static integrity check for project.pbxproj, runnable without a Mac.
#
#   powershell -ExecutionPolicy Bypass -File scripts\validate-project.ps1
#
# Catches the class of corruption that made the original project unopenable:
# duplicate object IDs (the same 24-hex key defining a PBXBuildFile *and* an
# XCBuildConfiguration), references to IDs that are never defined, build-phase
# entries pointing at PBXFileReference IDs instead of PBXBuildFile IDs, source
# files listed in the project but absent from disk, and Info.plist wrongly
# copied as a bundle resource.

$ErrorActionPreference = 'Stop'

$root       = Resolve-Path (Join-Path $PSScriptRoot '..')
$projectDir = Join-Path $root 'MediaPlayerApp\MediaPlayerApp.xcodeproj'
$pbxPath    = Join-Path $projectDir 'project.pbxproj'
$sourceDir  = Join-Path $root 'MediaPlayerApp\MediaPlayerApp'

if (-not (Test-Path $pbxPath)) { throw "Not found: $pbxPath" }

$text = Get-Content $pbxPath -Raw
$errors = @()
$warnings = @()

# --- 1. Definitions: "<ID> /* comment */ = {isa = <Type>;" ------------------
$defPattern = '(?m)^\s{2,}([0-9A-F]{24})\s*(?:/\*[^*]*\*/\s*)?=\s*\{\s*isa\s*=\s*([A-Za-z]+)\s*;'
$defs = @{}
foreach ($m in [regex]::Matches($text, $defPattern)) {
    $id = $m.Groups[1].Value
    $isa = $m.Groups[2].Value
    if ($defs.ContainsKey($id)) {
        $errors += "DUPLICATE ID $id defined as both $($defs[$id]) and $isa"
    } else {
        $defs[$id] = $isa
    }
}
Write-Output "Objects defined: $($defs.Count)"

# --- 2. Every referenced ID must exist ------------------------------------
$allIDs = [regex]::Matches($text, '[0-9A-F]{24}') | ForEach-Object { $_.Value } | Sort-Object -Unique
foreach ($id in $allIDs) {
    if (-not $defs.ContainsKey($id)) {
        $errors += "UNDEFINED ID referenced: $id"
    }
}

# --- 3. rootObject must be the PBXProject ---------------------------------
$rootMatch = [regex]::Match($text, 'rootObject\s*=\s*([0-9A-F]{24})')
if (-not $rootMatch.Success) {
    $errors += "No rootObject"
} elseif ($defs[$rootMatch.Groups[1].Value] -ne 'PBXProject') {
    $errors += "rootObject $($rootMatch.Groups[1].Value) is $($defs[$rootMatch.Groups[1].Value]), expected PBXProject"
}

# --- 4. Build phases must list PBXBuildFile IDs ---------------------------
function Get-PhaseFileIDs([string]$phaseIsa) {
    $ids = @()
    $pattern = "(?s)isa = $phaseIsa;.*?files = \((.*?)\);"
    foreach ($m in [regex]::Matches($text, $pattern)) {
        foreach ($f in [regex]::Matches($m.Groups[1].Value, '([0-9A-F]{24})')) {
            $ids += $f.Groups[1].Value
        }
    }
    return $ids
}

foreach ($phase in @('PBXSourcesBuildPhase', 'PBXResourcesBuildPhase', 'PBXFrameworksBuildPhase')) {
    foreach ($id in (Get-PhaseFileIDs $phase)) {
        if ($defs[$id] -ne 'PBXBuildFile') {
            $errors += "$phase lists $id which is a $($defs[$id]), expected PBXBuildFile"
        }
    }
}

# --- 5. Every PBXBuildFile fileRef must point at a PBXFileReference -------
foreach ($m in [regex]::Matches($text, 'isa = PBXBuildFile;\s*fileRef = ([0-9A-F]{24})')) {
    $ref = $m.Groups[1].Value
    if ($defs[$ref] -ne 'PBXFileReference') {
        $errors += "PBXBuildFile fileRef $ref is a $($defs[$ref]), expected PBXFileReference"
    }
}

# --- 6. Config lists must reference XCBuildConfiguration -----------------
foreach ($m in [regex]::Matches($text, '(?s)isa = XCConfigurationList;.*?buildConfigurations = \((.*?)\);')) {
    foreach ($c in [regex]::Matches($m.Groups[1].Value, '([0-9A-F]{24})')) {
        $id = $c.Groups[1].Value
        if ($defs[$id] -ne 'XCBuildConfiguration') {
            $errors += "XCConfigurationList references $id which is a $($defs[$id])"
        }
    }
}

# --- 7. buildConfigurationList must point at an XCConfigurationList ------
foreach ($m in [regex]::Matches($text, 'buildConfigurationList = ([0-9A-F]{24})')) {
    $id = $m.Groups[1].Value
    if ($defs[$id] -ne 'XCConfigurationList') {
        $errors += "buildConfigurationList $id is a $($defs[$id]), expected XCConfigurationList"
    }
}

# --- 8. Declared source files must exist on disk -------------------------
$declared = @()
foreach ($m in [regex]::Matches($text, 'isa = PBXFileReference;[^}]*path = ([^;]+);')) {
    $declared += $m.Groups[1].Value.Trim('"', ' ')
}
foreach ($file in $declared) {
    if ($file -eq 'MediaPlayerApp.app') { continue }
    if (-not (Test-Path (Join-Path $sourceDir $file))) {
        $errors += "MISSING ON DISK: $file"
    }
}

# --- 9. Every .swift on disk must be in the Sources phase ---------------
$onDisk = Get-ChildItem $sourceDir -Filter *.swift | ForEach-Object { $_.Name }
$sourcePhaseNames = @()
$srcMatch = [regex]::Match($text, '(?s)isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);')
if ($srcMatch.Success) {
    foreach ($m in [regex]::Matches($srcMatch.Groups[1].Value, '/\* ([^*]+?) in Sources \*/')) {
        $sourcePhaseNames += $m.Groups[1].Value.Trim()
    }
}
foreach ($f in $onDisk) {
    if ($sourcePhaseNames -notcontains $f) {
        $errors += "ORPHANED: $f exists on disk but is not in the Sources build phase"
    }
}
foreach ($f in $sourcePhaseNames) {
    if ($onDisk -notcontains $f) {
        $errors += "GHOST: $f is in the Sources build phase but not on disk"
    }
}

# --- 10. Info.plist must not be a bundle resource ----------------------
if ($text -match 'Info\.plist in Resources') {
    $errors += "Info.plist is in the Resources build phase; Xcode rejects this when INFOPLIST_FILE is also set"
}
if ($text -notmatch 'INFOPLIST_FILE') {
    $errors += "INFOPLIST_FILE is not set"
}

# --- 11. Shared scheme present and pointing at the real target ---------
$schemePath = Join-Path $projectDir 'xcshareddata\xcschemes\MediaPlayerApp.xcscheme'
if (-not (Test-Path $schemePath)) {
    $errors += "No shared scheme; 'xcodebuild -scheme MediaPlayerApp' will fail"
} else {
    $scheme = Get-Content $schemePath -Raw
    $targetIDs = @()
    foreach ($m in [regex]::Matches($text, '(?s)isa = PBXNativeTarget;.*?\}')) { }
    $nativeTargetID = ($defs.GetEnumerator() | Where-Object { $_.Value -eq 'PBXNativeTarget' } | Select-Object -First 1).Key
    if ($scheme -notmatch [regex]::Escape($nativeTargetID)) {
        $errors += "Scheme does not reference the native target ID $nativeTargetID"
    }
}

# --- 12. Asset catalog files referenced by Contents.json must exist ----
$appIconSet = Join-Path $sourceDir 'Assets.xcassets\AppIcon.appiconset'
if (Test-Path (Join-Path $appIconSet 'Contents.json')) {
    $json = Get-Content (Join-Path $appIconSet 'Contents.json') -Raw | ConvertFrom-Json
    foreach ($img in $json.images) {
        if ($img.filename -and -not (Test-Path (Join-Path $appIconSet $img.filename))) {
            $errors += "AppIcon declares $($img.filename) but the file is missing"
        }
    }
}
$launchSet = Join-Path $sourceDir 'Assets.xcassets\LaunchIcon.imageset'
if (Test-Path (Join-Path $launchSet 'Contents.json')) {
    $json = Get-Content (Join-Path $launchSet 'Contents.json') -Raw | ConvertFrom-Json
    foreach ($img in $json.images) {
        if ($img.filename -and -not (Test-Path (Join-Path $launchSet $img.filename))) {
            $errors += "LaunchIcon declares $($img.filename) but the file is missing"
        }
    }
}

# --- 13. Info.plist must be valid XML --------------------------------
try {
    [xml](Get-Content (Join-Path $sourceDir 'Info.plist') -Raw) | Out-Null
} catch {
    $errors += "Info.plist is not well-formed XML: $($_.Exception.Message)"
}

# --- Report ----------------------------------------------------------
Write-Output "Swift files on disk: $($onDisk.Count)   in Sources phase: $($sourcePhaseNames.Count)"

if ($warnings.Count -gt 0) {
    Write-Output ''
    Write-Output "WARNINGS ($($warnings.Count)):"
    $warnings | ForEach-Object { Write-Output "  - $_" }
}

Write-Output ''
if ($errors.Count -eq 0) {
    Write-Output 'PASS: project.pbxproj is internally consistent.'
    exit 0
} else {
    Write-Output "FAIL: $($errors.Count) problem(s):"
    $errors | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
