param(
  [Parameter(Mandatory = $true)][string]$ResultJson,
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function Resolve-OutputPath {
  param([string]$InputPath, [string]$RequestedPath)

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    return $RequestedPath
  }

  $dir = Split-Path -Parent (Resolve-Path $InputPath)
  Join-Path $dir "manual-reminder-card.png"
}

function New-RoundedRectPath {
  param(
    [float]$X,
    [float]$Y,
    [float]$Width,
    [float]$Height,
    [float]$Radius
  )

  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $diameter = $Radius * 2
  $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
  $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
  $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  $path
}

function Draw-RoundedRect {
  param(
    [System.Drawing.Graphics]$Graphics,
    [System.Drawing.RectangleF]$Rect,
    [float]$Radius,
    [System.Drawing.Brush]$Brush,
    [System.Drawing.Pen]$Pen = $null
  )

  $path = New-RoundedRectPath -X $Rect.X -Y $Rect.Y -Width $Rect.Width -Height $Rect.Height -Radius $Radius
  $Graphics.FillPath($Brush, $path)
  if ($Pen) {
    $Graphics.DrawPath($Pen, $path)
  }
  $path.Dispose()
}

function Draw-Text {
  param(
    [System.Drawing.Graphics]$Graphics,
    [string]$Text,
    [System.Drawing.Font]$Font,
    [System.Drawing.Brush]$Brush,
    [float]$X,
    [float]$Y,
    [float]$Width,
    [float]$Height,
    [string]$Alignment = "Near"
  )

  $format = [System.Drawing.StringFormat]::new()
  $format.Alignment = [System.Drawing.StringAlignment]::$Alignment
  $format.LineAlignment = [System.Drawing.StringAlignment]::Near
  $format.Trimming = [System.Drawing.StringTrimming]::EllipsisWord
  $Graphics.DrawString($Text, $Font, $Brush, [System.Drawing.RectangleF]::new($X, $Y, $Width, $Height), $format)
  $format.Dispose()
}

function Get-ManualItems {
  param([object[]]$Results)

  @($Results | Where-Object {
    $_.name -in @("muyuan", "lpgpt") -and
    $_.status -in @("manual_reminder", "failed", "unknown", "network_error")
  })
}

$resultPath = Resolve-Path $ResultJson
$results = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = Get-ManualItems -Results $results
if ($items.Count -eq 0) {
  throw "No manual reminder items found in $resultPath"
}

$output = Resolve-OutputPath -InputPath $resultPath -RequestedPath $OutputPath
$width = 1200
$height = 1500
$bitmap = [System.Drawing.Bitmap]::new($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$fontFamily = "Microsoft YaHei UI"
$titleFont = [System.Drawing.Font]::new($fontFamily, 50, [System.Drawing.FontStyle]::Bold)
$subtitleFont = [System.Drawing.Font]::new($fontFamily, 24, [System.Drawing.FontStyle]::Regular)
$metaFont = [System.Drawing.Font]::new($fontFamily, 20, [System.Drawing.FontStyle]::Regular)
$siteFont = [System.Drawing.Font]::new($fontFamily, 32, [System.Drawing.FontStyle]::Bold)
$bodyFont = [System.Drawing.Font]::new($fontFamily, 22, [System.Drawing.FontStyle]::Regular)
$pillFont = [System.Drawing.Font]::new($fontFamily, 18, [System.Drawing.FontStyle]::Bold)
$monoFont = [System.Drawing.Font]::new("Consolas", 18, [System.Drawing.FontStyle]::Regular)

$ink = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(30, 30, 33))
$muted = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(110, 110, 118))
$blue = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0, 102, 204))
$whiteGlass = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(214, 255, 255, 255))
$softWhite = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
$pillBg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(232, 245, 248, 255))
$pillText = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(48, 91, 154))
$linePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(120, 255, 255, 255), 2)
$glassPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 2)

try {
  $bgRect = [System.Drawing.Rectangle]::new(0, 0, $width, $height)
  $bgBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    $bgRect,
    [System.Drawing.Color]::FromArgb(246, 248, 252),
    [System.Drawing.Color]::FromArgb(226, 239, 255),
    45
  )
  $graphics.FillRectangle($bgBrush, $bgRect)
  $bgBrush.Dispose()

  $orb1 = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.Rectangle]::new(80, 90, 460, 460),
    [System.Drawing.Color]::FromArgb(168, 218, 255),
    [System.Drawing.Color]::FromArgb(40, 255, 255, 255),
    45
  )
  $graphics.FillEllipse($orb1, 80, 90, 460, 460)
  $orb1.Dispose()

  $orb2 = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.Rectangle]::new(700, 120, 430, 430),
    [System.Drawing.Color]::FromArgb(180, 231, 225),
    [System.Drawing.Color]::FromArgb(30, 255, 255, 255),
    25
  )
  $graphics.FillEllipse($orb2, 700, 120, 430, 430)
  $orb2.Dispose()

  $cardRect = [System.Drawing.RectangleF]::new(90, 115, 1020, 1260)
  Draw-RoundedRect -Graphics $graphics -Rect $cardRect -Radius 46 -Brush $whiteGlass -Pen $glassPen
  $highlight = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(180, 255, 255, 255), 3)
  $graphics.DrawLine($highlight, 135, 150, 1055, 150)
  $highlight.Dispose()

  Draw-Text -Graphics $graphics -Text "bb-browser daily check-in" -Font $metaFont -Brush $muted -X 150 -Y 180 -Width 900 -Height 34
  Draw-Text -Graphics $graphics -Text "公益站签到提醒" -Font $titleFont -Brush $ink -X 150 -Y 232 -Width 900 -Height 72
  Draw-Text -Graphics $graphics -Text "以下站点已进入手动提醒模式。自动化不会打开这些页面，只提醒你按需处理。" -Font $subtitleFont -Brush $muted -X 150 -Y 326 -Width 860 -Height 82

  $y = 455
  foreach ($item in $items) {
    $section = [System.Drawing.RectangleF]::new(150, $y, 900, 285)
    Draw-RoundedRect -Graphics $graphics -Rect $section -Radius 28 -Brush $softWhite -Pen $linePen

    Draw-Text -Graphics $graphics -Text ([string]$item.name) -Font $siteFont -Brush $ink -X 190 -Y ($y + 34) -Width 440 -Height 46
    $pill = [System.Drawing.RectangleF]::new(760, $y + 34, 235, 42)
    Draw-RoundedRect -Graphics $graphics -Rect $pill -Radius 21 -Brush $pillBg -Pen $null
    Draw-Text -Graphics $graphics -Text ([string]$item.status) -Font $pillFont -Brush $pillText -X 760 -Y ($y + 43) -Width 235 -Height 24 -Alignment "Center"

    Draw-Text -Graphics $graphics -Text "地址" -Font $bodyFont -Brush $muted -X 190 -Y ($y + 108) -Width 90 -Height 36
    Draw-Text -Graphics $graphics -Text ([string]$item.finalUrl) -Font $bodyFont -Brush $blue -X 282 -Y ($y + 108) -Width 700 -Height 38
    Draw-Text -Graphics $graphics -Text "原因" -Font $bodyFont -Brush $muted -X 190 -Y ($y + 158) -Width 90 -Height 36
    Draw-Text -Graphics $graphics -Text ([string]$item.reason) -Font $bodyFont -Brush $ink -X 282 -Y ($y + 158) -Width 700 -Height 70
    Draw-Text -Graphics $graphics -Text "截图" -Font $bodyFont -Brush $muted -X 190 -Y ($y + 232) -Width 90 -Height 36
    $shot = if ($item.screenshot) { [string]$item.screenshot } else { "无" }
    Draw-Text -Graphics $graphics -Text $shot -Font $bodyFont -Brush $ink -X 282 -Y ($y + 232) -Width 700 -Height 36

    $y += 325
  }

  $reportBox = [System.Drawing.RectangleF]::new(150, 1135, 900, 145)
  Draw-RoundedRect -Graphics $graphics -Rect $reportBox -Radius 24 -Brush ([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(180, 245, 247, 251))) -Pen $linePen
  Draw-Text -Graphics $graphics -Text "报告路径" -Font $metaFont -Brush $muted -X 190 -Y 1168 -Width 800 -Height 30
  Draw-Text -Graphics $graphics -Text ([string]$resultPath) -Font $monoFont -Brush $ink -X 190 -Y 1210 -Width 800 -Height 48
  Draw-Text -Graphics $graphics -Text "由 Codex 自动化通过 Gmail connector 发送" -Font $metaFont -Brush $muted -X 150 -Y 1308 -Width 900 -Height 32 -Alignment "Center"

  $dir = Split-Path -Parent $output
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $bitmap.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host $output
} finally {
  $graphics.Dispose()
  $bitmap.Dispose()
  $titleFont.Dispose()
  $subtitleFont.Dispose()
  $metaFont.Dispose()
  $siteFont.Dispose()
  $bodyFont.Dispose()
  $pillFont.Dispose()
  $monoFont.Dispose()
  $ink.Dispose()
  $muted.Dispose()
  $blue.Dispose()
  $whiteGlass.Dispose()
  $softWhite.Dispose()
  $pillBg.Dispose()
  $pillText.Dispose()
  $linePen.Dispose()
  $glassPen.Dispose()
}


