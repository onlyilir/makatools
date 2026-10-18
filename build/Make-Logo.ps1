# Makes logo.png and Makatools.ico (in assets\ unless -OutDir says otherwise).
#   Neutral logo (the public one):  powershell -ExecutionPolicy Bypass -File build\Make-Logo.ps1
#   From a photo:                   powershell -ExecutionPolicy Bypass -File build\Make-Logo.ps1 -Photo <photo.jpg> -X 1300 -Y 897 -Size 766
# For a photo, X, Y and Size are the square to crop, in pixels of the original photo; it gets a round mask and a ring.
param(
    [string]$Photo,
    [int]$X, [int]$Y, [int]$Size,
    [string]$OutDir
)
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'assets' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$blue = [System.Drawing.Color]::FromArgb(255, 0, 120, 215)

$src = $null
if ($Photo) {
    $src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Photo).Path)
    # Phone photos are often stored sideways with an EXIF rotation tag (0x0112)
    if ($src.PropertyIdList -contains 0x0112) {
        switch ([int]$src.GetPropertyItem(0x0112).Value[0]) {
            3 { $src.RotateFlip('Rotate180FlipNone') }
            6 { $src.RotateFlip('Rotate90FlipNone') }
            8 { $src.RotateFlip('Rotate270FlipNone') }
        }
    }
}

# Four-pointed sparkle centred on (cx, cy): the "clean" mark on the neutral logo
function Add-Sparkle($Path, [single]$Cx, [single]$Cy, [single]$R) {
    $t = $R * 0.22
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($Cx, ($Cy - $R))), (New-Object System.Drawing.PointF(($Cx + $t), ($Cy - $t))),
        (New-Object System.Drawing.PointF(($Cx + $R), $Cy)), (New-Object System.Drawing.PointF(($Cx + $t), ($Cy + $t))),
        (New-Object System.Drawing.PointF($Cx, ($Cy + $R))), (New-Object System.Drawing.PointF(($Cx - $t), ($Cy + $t))),
        (New-Object System.Drawing.PointF(($Cx - $R), $Cy)), (New-Object System.Drawing.PointF(($Cx - $t), ($Cy - $t))))
    $Path.AddPolygon($pts)
}

# Draws the round logo at any size
function New-LogoBitmap([int]$Px) {
    $bmp = New-Object System.Drawing.Bitmap($Px, $Px, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $ring = [math]::Max(1, [int]($Px * 0.06))
    $inner = New-Object System.Drawing.Rectangle($ring, $ring, ($Px - 2 * $ring), ($Px - 2 * $ring))
    if ($src) {
        $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
        $clip.AddEllipse($inner)
        $g.SetClip($clip)
        $g.DrawImage($src, $inner, (New-Object System.Drawing.Rectangle($X, $Y, $Size, $Size)), 'Pixel')
        $g.ResetClip()
        $pen = New-Object System.Drawing.Pen($blue, $ring)
        $g.DrawEllipse($pen, ($ring / 2), ($ring / 2), ($Px - $ring), ($Px - $ring))
        $pen.Dispose()
    } else {
        # Blue disc, lighter at the top, with a white "M" and a sparkle
        $disc = New-Object System.Drawing.Rectangle(0, 0, $Px, $Px)
        $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush($disc, [System.Drawing.Color]::FromArgb(255, 30, 144, 235), [System.Drawing.Color]::FromArgb(255, 0, 84, 166), 90)
        $g.FillEllipse($fill, 0, 0, ($Px - 1), ($Px - 1))
        $fill.Dispose()
        $font = New-Object System.Drawing.Font('Segoe UI Black', [single]($Px * 0.50), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'
        $fmt.LineAlignment = 'Center'
        $box = New-Object System.Drawing.RectangleF(0, ($Px * 0.03), $Px, $Px)
        $g.DrawString('M', $font, [System.Drawing.Brushes]::White, $box, $fmt)
        $font.Dispose()
        if ($Px -ge 32) {
            $spark = New-Object System.Drawing.Drawing2D.GraphicsPath
            Add-Sparkle $spark ($Px * 0.76) ($Px * 0.25) ($Px * 0.11)
            $g.FillPath([System.Drawing.Brushes]::White, $spark)
            $spark.Dispose()
        }
    }
    $g.Dispose()
    return $bmp
}

$big = New-LogoBitmap 512
$big.Save((Join-Path $OutDir 'logo.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$big.Dispose()

# Classic .ico frame: BITMAPINFOHEADER (height doubled), 32-bit BGRA rows bottom-up, then an
# all-zero AND mask (the alpha channel does the masking). Every Windows version and .NET read this.
function ConvertTo-IcoBitmapFrame($Bitmap) {
    $n = $Bitmap.Width
    $rect = New-Object System.Drawing.Rectangle(0, 0, $n, $n)
    $data = $Bitmap.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $pixels = New-Object byte[] ($data.Stride * $n)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    $Bitmap.UnlockBits($data)
    $maskRow = [int]([math]::Ceiling($n / 32) * 4)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]40); $bw.Write([int32]$n); $bw.Write([int32]($n * 2))
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0)
    $bw.Write([uint32]($n * $n * 4 + $maskRow * $n))
    $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($row = $n - 1; $row -ge 0; $row--) { $bw.Write($pixels, $row * $data.Stride, $n * 4) }
    $bw.Write((New-Object byte[] ($maskRow * $n)))
    $bw.Flush()
    return , $ms.ToArray()   # the comma stops PowerShell unrolling the array into single bytes
}

# .ico: classic bitmap frames up to 128 px, a PNG frame at 256 px (the usual layout)
$sizes = 16, 24, 32, 48, 64, 128, 256
$frames = foreach ($s in $sizes) {
    $b = New-LogoBitmap $s
    if ($s -ge 256) {
        $ms = New-Object System.IO.MemoryStream
        $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
    } else {
        $bytes = ConvertTo-IcoBitmapFrame $b
    }
    $b.Dispose()
    , $bytes
}
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$frames[$i].Length); $w.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($f in $frames) { $w.Write([byte[]]$f) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'Makatools.ico'), $out.ToArray())
if ($src) { $src.Dispose() }
Write-Output "Wrote $OutDir\logo.png and $OutDir\Makatools.ico"
