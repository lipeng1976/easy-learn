param(
  [string]$OutDir = "",
  [int]$TitleSize = 22,
  [int]$BodySize = 36,
  [string]$Ink = "20,30,90",
  # The answer page keeps its own knobs so an OCR-robustness probe can render
  # faded / tiny variants of the SAME handwriting and check whether the
  # returned `confidence` actually drops. The defaults below are the values
  # the e2e run depends on - do not change them.
  [int]$AnswerTitleSize = 26,
  [int]$AnswerBodySize = 42,
  [string]$AnswerInk = "18,18,120"
)

# Renders the three sample "homework photos" that scripts/e2e-local-homework.mjs
# feeds to the gateway:
#   homework_check.png      a workbook page with two deliberately wrong answers
#   homework_list.png       the assignment list a student copied into a notebook
#   answer_handwriting.png  the handwritten answer under ONE question
#
# Why a renderer instead of a checked-in JPEG: the acceptance run needs the
# WRONG answers to be wrong in a known way ("9 x 3 = 26" must be 27), and it
# needs to prove the model actually read the image rather than guessing. A
# synthetic page makes the expected result exact.
#
# Uses only System.Drawing, which ships with Windows - no network access and
# no third-party packages, so this runs on a machine with no internet.
#
# The page text lives in fixtures/*.txt as UTF-8 rather than inside this file:
# keeping this script pure ASCII avoids the encoding trap where a .ps1 saved
# as UTF-8 without BOM turns CJK text into mojibake.
#
#   powershell -ExecutionPolicy Bypass -File scripts/make-homework-photos.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/make-homework-photos.ps1 -OutDir D:\tmp\hw

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $env:TEMP "hw_test"
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$fixtures = Join-Path $PSScriptRoot "fixtures"
if (-not (Test-Path $fixtures)) { throw "fixtures folder not found: $fixtures" }

function New-HomeworkPhoto {
  param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [Parameter(Mandatory=$true)][int]$TitleSize,
    [Parameter(Mandatory=$true)][int]$BodySize,
    [Parameter(Mandatory=$true)][string]$Ink
  )

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

  # Faint shading top and bottom so the page reads as a photo of paper
  # rather than as a pure render.
  $shade = New-Object System.Drawing.SolidBrush(
    [System.Drawing.Color]::FromArgb(14, 120, 130, 150))
  $g.FillRectangle($shade, 0, 0, $w, 60)
  $g.FillRectangle($shade, 0, $h - 60, $w, 60)

  $rulePen = New-Object System.Drawing.Pen(
    [System.Drawing.Color]::FromArgb(120, 170, 190, 205), 1.6)
  $marginPen = New-Object System.Drawing.Pen(
    [System.Drawing.Color]::FromArgb(150, 220, 130, 130), 2.0)

  $topMargin = 150
  $ruleGap = 78
  $y = $topMargin
  while ($y -lt $h - 120) {
    $g.DrawLine($rulePen, 90, $y, $w - 70, $y)
    $y += $ruleGap
  }
  $g.DrawLine($marginPen, 132, 110, 132, $h - 110)

  # KaiTi is the closest thing to handwriting among the fonts that ship with
  # Windows; a printed font would make the vision test easier than reality.
  $titleFont = New-Object System.Drawing.Font(
    "KaiTi", $TitleSize, [System.Drawing.FontStyle]::Bold)
  $bodyFont = New-Object System.Drawing.Font("KaiTi", $BodySize)
  $titleBrush = New-Object System.Drawing.SolidBrush(
    [System.Drawing.Color]::FromArgb(60, 70, 90))
  $inkParts = $Ink.Split(",") | ForEach-Object { [int]$_ }
  $inkBrush = New-Object System.Drawing.SolidBrush(
    [System.Drawing.Color]::FromArgb(255, $inkParts[0], $inkParts[1], $inkParts[2]))

  $g.DrawString($title, $titleFont, $titleBrush, 150, 92)

  # Deterministic per-line jitter: the page should look handwritten, but the
  # same input must always produce the same image, or a repeated run would
  # miss the gateway cache and the timings would not be comparable.
  $seed = 7
  $cy = $topMargin + 26
  foreach ($line in $body) {
    $seed = ($seed * 31 + 17) % 997
    $dx = ($seed % 7) - 3
    $dy = ($seed % 5) - 2
    $g.DrawString($line, $bodyFont, $inkBrush, (150 + $dx), ($cy + $dy))
    $cy += $ruleGap
  }

  $g.Dispose()
  $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  $info = Get-Item $OutFile
  Write-Output ("rendered {0} ({1} bytes)" -f $info.FullName, $info.Length)
}

New-HomeworkPhoto `
  -InFile (Join-Path $fixtures "homework_check.txt") `
  -OutFile (Join-Path $OutDir "homework_check.png") `
  -TitleSize $TitleSize -BodySize $BodySize -Ink $Ink

New-HomeworkPhoto `
  -InFile (Join-Path $fixtures "homework_list.txt") `
  -OutFile (Join-Path $OutDir "homework_list.png") `
  -TitleSize 24 -BodySize 30 -Ink "25,25,25"

# The answer page: what a student wrote under ONE question.
#
# It deliberately contains the same wrong value as the check page ("9 x 3 = 26")
# so the two routes can be compared on identical content: the check route must
# report it as an item, the answer route must TRANSCRIBE it verbatim and not
# correct it. If the answer route ever returns "27", the model is solving the
# problem instead of reading the handwriting - and the student would see a
# correct answer he never wrote.
New-HomeworkPhoto `
  -InFile (Join-Path $fixtures "answer_handwriting.txt") `
  -OutFile (Join-Path $OutDir "answer_handwriting.png") `
  -TitleSize $AnswerTitleSize -BodySize $AnswerBodySize -Ink $AnswerInk

Write-Output ("output folder: {0}" -f $OutDir)
