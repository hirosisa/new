# Generates the app icon and launch icon PNGs for MediaPlayerApp.
# Runs on Windows PowerShell 5.1+ using System.Drawing. Re-run any time to regenerate.
#
#   powershell -ExecutionPolicy Bypass -File scripts\generate-icons.ps1
#
# App icons must be opaque (no alpha channel), so the canvas is 24bpp RGB.

Add-Type -AssemblyName System.Drawing

$assets = Join-Path $PSScriptRoot '..\MediaPlayerApp\MediaPlayerApp\Assets.xcassets'
$appIconDir = Join-Path $assets 'AppIcon.appiconset'
$launchDir = Join-Path $assets 'LaunchIcon.imageset'

foreach ($d in @($appIconDir, $launchDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

function New-Icon {
    param(
        [int]$Size,
        [string]$Path,
        [bool]$Opaque = $true
    )

    $fmt = if ($Opaque) { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb }
           else { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb }

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, $fmt)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)

    if ($Opaque) {
        # Diagonal gradient backdrop: deep slate -> near black
        $c1 = [System.Drawing.Color]::FromArgb(255, 32, 34, 44)
        $c2 = [System.Drawing.Color]::FromArgb(255, 12, 12, 16)
        $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)
        $g.FillRectangle($bg, $rect)
        $bg.Dispose()
    } else {
        $g.Clear([System.Drawing.Color]::Transparent)
    }

    # Orange ring
    $orange = [System.Drawing.Color]::FromArgb(255, 255, 149, 0)
    $ringPen = New-Object System.Drawing.Pen($orange, [float]($Size * 0.055))
    $inset = $Size * 0.20
    $ringRect = New-Object System.Drawing.RectangleF(
        [float]$inset, [float]$inset,
        [float]($Size - 2 * $inset), [float]($Size - 2 * $inset))
    $g.DrawEllipse($ringPen, $ringRect)
    $ringPen.Dispose()

    # Play triangle, optically centred inside the ring
    $cx = $Size / 2.0
    $cy = $Size / 2.0
    $r = $Size * 0.115
    $pts = @(
        (New-Object System.Drawing.PointF([float]($cx - $r * 0.72 + $Size * 0.018), [float]($cy - $r))),
        (New-Object System.Drawing.PointF([float]($cx - $r * 0.72 + $Size * 0.018), [float]($cy + $r))),
        (New-Object System.Drawing.PointF([float]($cx + $r * 1.08 + $Size * 0.018), [float]$cy))
    )
    $fill = New-Object System.Drawing.SolidBrush($orange)
    $g.FillPolygon($fill, $pts)
    $fill.Dispose()

    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $kb = [math]::Round((Get-Item $Path).Length / 1KB, 1)
    Write-Output ("  {0,-22} {1,5}x{1,-5} {2,7} KB" -f (Split-Path $Path -Leaf), $Size, $kb)
}

Write-Output 'AppIcon (single 1024 universal icon, Xcode 14+ style):'
New-Icon -Size 1024 -Path (Join-Path $appIconDir 'icon-1024.png') -Opaque $true

Write-Output 'LaunchIcon (transparent, 1x/2x/3x):'
New-Icon -Size 160 -Path (Join-Path $launchDir 'launch-icon.png')    -Opaque $false
New-Icon -Size 320 -Path (Join-Path $launchDir 'launch-icon@2x.png') -Opaque $false
New-Icon -Size 480 -Path (Join-Path $launchDir 'launch-icon@3x.png') -Opaque $false

Write-Output 'Done.'
