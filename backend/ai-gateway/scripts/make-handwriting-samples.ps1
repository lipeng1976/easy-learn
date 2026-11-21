param(
  [string]$OutDir = "",
  [string]$InFile = "",
  [string]$Font = "KaiTi",
  [int]$TitleSize = 30,
  [int]$BodySize = 40,
  [double]$CharJitterX = 0,
  [double]$CharJitterY = 0,
  [double]$LineJitterY = 0,
  [double]$RotateDeg = 0,
  [double]$SizeJitter = 0,
  [double]$BaselineDrift = 0,
  [double]$Lighting = 0,
  [string]$Ink = "32,40,72",
  [int]$Seed = 20260915,
  [string]$OutName = "sample.png",
  [switch]$Grid
)

# Renders one "handwritten homework list" photo for the handwriting-OCR probe.
#
# Why per-character rendering instead of a single DrawString: the thing that
# makes handwriting hard is not the glyph shapes, it is that every character
# sits at a slightly different height, angle and size, and the baseline drifts
# across the line. Drawing a whole line with one call produces typeset output
# no matter which font is used - the earlier sample used KaiTi with a 3px
# per-line offset and that is still, measurably, printed text.
#
#   jitter/rotate/size  -> per-character placement noise (the real difficulty)
#   BaselineDrift       -> the line slowly rises or falls, like a hand does
#   Lighting            -> uneven phone-camera exposure across the page
#
# Deterministic LCG: a repeated run must produce a byte-identical file, or the
# gateway cache would miss and the timings would stop being comparable.
#
# Fonts are resolved explicitly and the RESOLVED name is echoed. A silent
# fallback to KaiTi would make "cursive" samples that are not cursive, and the
# whole measurement would be quietly meaningless.
#
# Only System.Drawing is used - ships with Windows, no network, no packages.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $env:TEMP "hw_hand" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
if ([string]::IsNullOrWhiteSpace($InFile)) {
  $InFile = Join-Path (Join-Path $PSScriptRoot "fixtures") "homework_list.txt"
}
if (-not (Test-Path $InFile)) { throw "input text not found: $InFile" }

# --- font resolution, with the fallback made visible -------------------------
# Checked against the installed-font list rather than by constructing a
# FontFamily: a family that is missing makes GDI+ silently fall back to a
# default face, and "cursive" samples that are not cursive would make the whole
# measurement meaningless. The resolved name is echoed for the same reason.
$installed = New-Object -TypeName System.Drawing.Text.InstalledFontCollection
$available = @()
foreach ($fam in $installed.Families) { $available += [string]$fam.Name }

if ($available -contains $Font) {
  $familyName = $Font
} else {
  $cjk = $available | Where-Object { $_ -match 'Kai|Song|Hei|Xing|Shu|Fang|You|Ming|YaHei' }
  Write-Output ("WARNING font '{0}' is not installed -> using KaiTi. CJK faces present: {1}" -f `
    $Font, ($cjk -join ', '))
  $familyName = "KaiTi"
  if ($available -notcontains "KaiTi") { throw "neither '$Font' nor 'KaiTi' is installed" }
}
$installed.Dispose()

# Fonts are built per character down in the body loop - see the note there for
# why a prebuilt lookup table is not used.

# --- deterministic RNG -------------------------------------------------------
$script:rand = [double]$Seed
function Next-Bipolar {
  # returns a value in [-1, 1)
  $script:rand = ($script:rand * 1664525.0 + 1013904223.0) % 2147483648.0
  return (($script:rand / 2147483648.0) * 2.0) - 1.0
}

$lines = [System.IO.File]::ReadAllLines($InFile, [System.Text.Encoding]::UTF8)
$lines = $lines | Where-Object { $_.Trim() -ne "" }
if ($lines.Count -lt 2) { throw "$InFile needs a title line and at least one body line" }
$title = $lines[0]
$body = $lines[1..($lines.Count - 1)]

$w = 1240
$h = 1754
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::FromArgb(252, 250, 243))

$ruleGap = [int]($BodySize * 1.75) + 14
$leftMargin = 150
$topMargin = 170
$maxX = $w - 90

if ($Grid) {
  $rulePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110, 170, 190, 205), 1.5)
  $y = $topMargin + [int]($BodySize * 1.3)
  while ($y -lt $h - 120) { $g.DrawLine($rulePen, 92, $y, $maxX, $y); $y += $ruleGap }
}

$inkParts = $Ink.Split(",") | ForEach-Object { [int]$_ }
$brush = New-Object System.Drawing.SolidBrush(
  [System.Drawing.Color]::FromArgb(255, $inkParts[0], $inkParts[1], $inkParts[2]))

# --- title -------------------------------------------------------------------
$titleFont = New-Object -TypeName System.Drawing.Font `
  -ArgumentList ([string]$familyName), ([float]$TitleSize)
$titleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 78, 100))
$g.DrawString($title, $titleFont, $titleBrush, [float]($leftMargin + 10), [float]($topMargin - 74))

# --- body: per character -----------------------------------------------------
# Advance is measured per glyph instead of using one fixed CJK cell. A fixed
# cell pushes Latin digits and letters onto full-width steps, which renders
# "P12" as "P 1 2" - a spacing that no student writes and that would make the
# recognition task look harder than the writing actually is.
$typo = [System.Drawing.StringFormat]::GenericTypographic
$y = [double]($topMargin + $BodySize)
foreach ($line in $body) {
  $x = [double]$leftMargin
  $drift = 0.0
  foreach ($ch in $line.ToCharArray()) {
    if ($ch -eq ' ') { $x += $BodySize * 0.42; continue }

    $dx = (Next-Bipolar) * $CharJitterX
    $dy = (Next-Bipolar) * $CharJitterY
    $rot = (Next-Bipolar) * $RotateDeg
    $scale = 1.0 + ((Next-Bipolar) * $SizeJitter)

    $drift += (Next-Bipolar) * $BaselineDrift

    $fsz = [int][math]::Round($BodySize * $scale)
    if ($fsz -lt 8) { $fsz = 8 }

    # The font is built here, per character, rather than read out of a
    # prebuilt table. A table lookup returned the Font's *string* form - the
    # value read back was "[Font: Name=KaiTi, Size=40, Units=3, ...]" - and
    # PowerShell's overload binder then tried to parse that string back into a
    # Font, failing with a baffling "not valid for 'units'" error. Building it
    # inline is slower but has no such failure mode, and a page of a few
    # hundred characters is not worth optimizing.
    $gl = New-Object -TypeName System.Drawing.Font `
      -ArgumentList ([string]$familyName), ([float]$fsz)

    $g.ResetTransform()
    $g.TranslateTransform([float]($x + $dx), [float]($y + $dy + $drift))
    $g.RotateTransform([float]$rot)
    $g.DrawString([string]$ch, $gl, $brush, [float]0, [float]0)
    $g.ResetTransform()

    $adv = [double]$g.MeasureString(
      [string]$ch, $gl, [System.Drawing.PointF]::new([float]0, [float]0), $typo).Width
    if ($adv -lt 4) { $adv = $BodySize * 0.45 }
    # A little breathing room so characters do not collide when the jitter
    # pushes two neighbours toward each other.
    $adv += $BodySize * 0.06

    $gl.Dispose()

    $x += $adv
  }
  $y += $ruleGap
}

# --- uneven exposure ---------------------------------------------------------
if ($Lighting -gt 0) {
  $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
  $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [System.Drawing.Color]::FromArgb([int](60 * $Lighting), 255, 252, 235),
    [System.Drawing.Color]::FromArgb([int](120 * $Lighting), 60, 66, 90),
    12.0)
  $g.FillRectangle($grad, $rect)
  $grad.Dispose()
}

$g.Dispose()
$outPath = Join-Path $OutDir $OutName
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$info = Get-Item $outPath
Write-Output ("rendered {0}  font={1}  {2} bytes" -f $OutName, $familyName, $info.Length)
