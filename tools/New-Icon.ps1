<#
.SYNOPSIS
    Renders the ALERION Update icon (assets\icon.ico with 16-256 px frames + assets\icon.png).
    Design: rounded square with a violet-to-cyan gradient, a white refresh ring and a download arrow.
#>
param([string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'))

Add-Type -AssemblyName System.Drawing
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

function New-RoundedRect {
    param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90); $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90); $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}

function New-ArrowHead {
    <# Triangle pointing along the tangent of the ring at the given angle (clockwise travel). #>
    param([float]$Cx, [float]$Cy, [float]$Radius, [float]$AngleDeg, [float]$Size)
    $a = $AngleDeg * [Math]::PI / 180
    $px = $Cx + $Radius * [Math]::Cos($a); $py = $Cy + $Radius * [Math]::Sin($a)
    $tx = -[Math]::Sin($a); $ty = [Math]::Cos($a)          # clockwise tangent
    $nx = [Math]::Cos($a); $ny = [Math]::Sin($a)           # outward normal
    $tip = New-Object System.Drawing.PointF(($px + $tx * $Size * 1.1), ($py + $ty * $Size * 1.1))
    $b1 = New-Object System.Drawing.PointF(($px + $nx * $Size), ($py + $ny * $Size))
    $b2 = New-Object System.Drawing.PointF(($px - $nx * $Size), ($py - $ny * $Size))
    return , @($tip, $b1, $b2)
}

function New-IconBitmap {
    param([int]$Size)
    $s = [float]$Size
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Background tile
    $pad = [Math]::Max(0.5, $s * 0.03)
    $tile = New-RoundedRect $pad $pad ($s - 2 * $pad) ($s - 2 * $pad) ($s * 0.23)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($s, $s)),
        [System.Drawing.Color]::FromArgb(255, 124, 58, 237), [System.Drawing.Color]::FromArgb(255, 6, 182, 212))
    $g.FillPath($grad, $tile)
    # Soft top highlight for depth
    $hl = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF(0, $s * 0.6)),
        [System.Drawing.Color]::FromArgb(60, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    $g.FillPath($hl, $tile)

    # Refresh ring: two arcs with arrow heads
    $cx = $s / 2; $cy = $s / 2; $r = $s * 0.27
    $w = [Math]::Max(1.6, $s * 0.075)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $w)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Flat'
    $rect = New-Object System.Drawing.RectangleF(($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
    $g.DrawArc($pen, $rect, 200, 125)
    $g.DrawArc($pen, $rect, 20, 125)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillPolygon($white, (New-ArrowHead $cx $cy $r 325 ($w * 1.25)))
    $g.FillPolygon($white, (New-ArrowHead $cx $cy $r 145 ($w * 1.25)))

    # Download arrow in the centre (dropped on tiny sizes where it would turn into noise)
    if ($Size -ge 32) {
        $aw = [Math]::Max(1.4, $s * 0.06)
        $apen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $aw)
        $apen.StartCap = 'Round'; $apen.EndCap = 'Round'; $apen.LineJoin = 'Round'
        $g.DrawLine($apen, $cx, ($cy - $s * 0.11), $cx, ($cy + $s * 0.09))
        $g.DrawLines($apen, [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF(($cx - $s * 0.075), ($cy + $s * 0.02))),
            (New-Object System.Drawing.PointF($cx, ($cy + $s * 0.095))),
            (New-Object System.Drawing.PointF(($cx + $s * 0.075), ($cy + $s * 0.02)))))
        $apen.Dispose()
    }
    $g.Dispose(); $pen.Dispose(); $white.Dispose(); $grad.Dispose(); $hl.Dispose()
    return $bmp
}

# ICO container with PNG-compressed frames (supported since Windows Vista)
$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$frames = foreach ($sz in $sizes) {
    $bmp = New-IconBitmap -Size $sz
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($sz -eq 256) { $bmp.Save((Join-Path $OutDir 'icon.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    [pscustomobject]@{ Size = $sz; Bytes = $ms.ToArray() }
}
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$f.Bytes.Length); $bw.Write([uint32]$offset)
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $bw.Write($f.Bytes) }
$bw.Flush()
[IO.File]::WriteAllBytes((Join-Path $OutDir 'icon.ico'), $out.ToArray())
Write-Host "Icon written to $OutDir"
