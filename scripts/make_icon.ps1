# =============================================================================
#  FHBrowser 图标生成脚本
#  - 用 System.Drawing（GDI+）按 9 个尺寸逐尺寸矢量重绘，不依赖第三方库
#  - 主体：蓝色渐变圆角底 + 白色 FH 连字（F 竖 = H 左竖，中横贯通）
#  - 输出：assets/icon/fhbrowser.ico + fhbrowser-<size>.png
#  - 改配色/几何只需改本文件的常量，然后重跑：
#      powershell -ExecutionPolicy Bypass -File scripts\make_icon.ps1
# =============================================================================
param(
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\assets\icon' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir | Out-Null
}

# 尺寸清单（Win7 任务栏 16/32、Alt+Tab 32/48、资源管理器 96/256）
$Sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256

# 渐变：左上 #1A73E8 → 右下 #0B57D0（与主界面 Google Blue 主色一致）
$ColorTop = [Drawing.ColorTranslator]::FromHtml('#1A73E8')
$ColorBottom = [Drawing.ColorTranslator]::FromHtml('#0B57D0')

# 1024 基准坐标系（与 fhbrowser.svg 完全一致）
# 图形整体占宽度 41%，四周留白充足（16px 下左右各约 4-5px 纯蓝）
$BaseSize = 1024.0
$BarW = 105.0          # 笔画宽（大尺寸）
$LeftX = 302.0         # 左竖（F 竖 / H 左竖）
$RightX = 618.0        # H 右竖
$TopY = 320.0          # 顶部
$MidY = 459.0          # 中横上沿（中点 511.5）
$BottomY = 703.0       # 底部
$Radius = 196.0        # 圆角半径
# F 上横宽度占比：大尺寸 63%，小尺寸压到 50% 给负空间让位
$FTopRatioLarge = 0.63
$FTopRatioSmall = 0.42

function Round-Away([double]$v) {
  return [int][Math]::Round($v, [MidpointRounding]::AwayFromZero)
}

function New-RoundPath([single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = [single]($r * 2)
  if ($d -gt $w) { $d = $w }
  if ($d -gt $h) { $d = $h }
  $p.AddArc(0, 0, $d, $d, 180, 90)
  $p.AddArc($w - $d, 0, $d, $d, 270, 90)
  $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
  $p.AddArc(0, $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function New-IconBitmap([int]$S) {
  $bmp = New-Object System.Drawing.Bitmap($S, $S, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
  # 整数坐标 + PixelOffsetMode.None：笔画边缘落在像素格上，避免半像素灰边
  $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::None
  $g.Clear([Drawing.Color]::Transparent)

  $k = $S / $BaseSize

  # 圆角底：小尺寸用纯色并收小圆角，避免渐变发灰、圆角过大像圆钮
  $r = $Radius
  if ($S -le 24) { $r = $Radius * 0.9 }
  $path = New-RoundPath $S $S ([single]($r * $k))
  if ($S -ge 32) {
    $p1 = New-Object System.Drawing.PointF(0, 0)
    $p2 = New-Object System.Drawing.PointF($S, $S)
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush($p1, $p2, $ColorTop, $ColorBottom)
  } else {
    $fill = New-Object System.Drawing.SolidBrush($ColorBottom)
  }
  $g.FillPath($fill, $path)

  # 白色 FH 连字（几何保证 16px 仍有 2px 笔画）
  $white = New-Object System.Drawing.SolidBrush([Drawing.Color]::White)
  $st = Round-Away($BarW * $k)
  if ($st -lt 2) { $st = 2 }
  $lx = Round-Away($LeftX * $k)
  $rx = Round-Away($RightX * $k)
  $top = Round-Away($TopY * $k)
  $mid = Round-Away($MidY * $k)
  $bot = Round-Away($BottomY * $k)

  # 左竖（F 竖与 H 左竖共用）
  $g.FillRectangle($white, $lx, $top, $st, ($bot - $top))
  # 小尺寸用 1px 细横笔，让 F 上横与中横之间留出 1px 负空间（否则 16px 糊成实心块）
  $hst = $st
  if ($S -le 24) { $hst = [Math]::Max(1, $st - 1) }
  # F 上横：小尺寸缩短，保证与 H 右竖之间留出可辨认的负空间
  $fRatio = $FTopRatioLarge
  if ($S -le 24) { $fRatio = $FTopRatioSmall }
  $fW = Round-Away(($rx + $st - $lx) * $fRatio)
  $g.FillRectangle($white, $lx, $top, $fW, $hst)
  # 中横（F 中横与 H 中横共用，贯通到右竖）
  $g.FillRectangle($white, $lx, $mid, (($rx + $st) - $lx), $hst)
  # H 右竖
  $g.FillRectangle($white, $rx, $top, $st, ($bot - $top))

  $fill.Dispose()
  $white.Dispose()
  $path.Dispose()
  $g.Dispose()
  return $bmp
}

# 32bpp 图标 → ICO 内部 DIB（BITMAPINFOHEADER + 自底向上 BGRA + 全 0 AND 掩码）
function Get-IconDib([Drawing.Bitmap]$bmp) {
  $S = $bmp.Width
  $rect = New-Object System.Drawing.Rectangle(0, 0, $S, $S)
  $data = $bmp.LockBits($rect,
    [Drawing.Imaging.ImageLockMode]::ReadOnly,
    [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $raw = New-Object byte[] ($stride * $S)
  [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
  $bmp.UnlockBits($data)

  $ms = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter($ms)
  $bw.Write([uint32]40)                    # biSize
  $bw.Write([int32]$S)                     # biWidth
  $bw.Write([int32]($S * 2))               # biHeight（XOR + AND）
  $bw.Write([uint16]1)                     # biPlanes
  $bw.Write([uint16]32)                    # biBitCount
  $bw.Write([uint32]0)                     # biCompression = BI_RGB
  $bw.Write([uint32]($S * $S * 4))         # biSizeImage
  $bw.Write([int32]0)                      # biXPelsPerMeter
  $bw.Write([int32]0)                      # biYPelsPerMeter
  $bw.Write([uint32]0)                     # biClrUsed
  $bw.Write([uint32]0)                     # biClrImportant
  for ($y = $S - 1; $y -ge 0; $y--) {
    $bw.Write($raw, ($y * $stride), ($S * 4))
  }
  $maskStride = [int]([Math]::Ceiling($S / 32.0) * 4)
  $zero = New-Object byte[] ($maskStride * $S)
  $bw.Write($zero, 0, $zero.Length)
  $bw.Flush()
  return $ms.ToArray()
}

$entries = @()
foreach ($s in $Sizes) {
  $bmp = New-IconBitmap $s
  $bmp.Save((Join-Path $OutDir ("fhbrowser-{0}.png" -f $s)),
    [Drawing.Imaging.ImageFormat]::Png)
  if ($s -ge 128) {
    # 128/256 用 PNG 压缩（Vista/Win7 均支持），显著缩小 ico
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
  } else {
    $bytes = Get-IconDib $bmp
  }
  $entries += [pscustomobject]@{ Size = $s; Data = $bytes }
  $bmp.Dispose()
}

$icoPath = Join-Path $OutDir 'fhbrowser.ico'
$fs = [IO.File]::Create($icoPath)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([uint16]0)                       # reserved
$bw.Write([uint16]1)                       # type = icon
$bw.Write([uint16]$entries.Count)

$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
  $dim = $e.Size
  if ($dim -ge 256) { $dim = 0 }           # 256 在 ICO 目录里写 0
  $bw.Write([byte]$dim)
  $bw.Write([byte]$dim)
  $bw.Write([byte]0)                       # color count
  $bw.Write([byte]0)                       # reserved
  $bw.Write([uint16]1)                     # planes
  $bw.Write([uint16]32)                    # bit count
  $bw.Write([uint32]$e.Data.Length)
  $bw.Write([uint32]$offset)
  $offset += $e.Data.Length
}
foreach ($e in $entries) {
  $bw.Write($e.Data, 0, $e.Data.Length)
}
$bw.Flush()
$bw.Close()
$fs.Close()

Write-Output ("OK: {0} ({1} entries, {2:N0} bytes)" -f $icoPath, $entries.Count,
  (Get-Item -LiteralPath $icoPath).Length)
foreach ($s in $Sizes) {
  Write-Output ("  png: fhbrowser-{0}.png" -f $s)
}