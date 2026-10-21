# Makes the mod.io listing image (16:9, 1280x720) from a game screenshot,
# cropping to the area around the bank window.
#   powershell -File tools\make-listing-image.ps1 -Source shot.png [-X 640 -Y 40 -Width 1280 -Height 720]
# The crop box is in screenshot pixels; it's widened or narrowed to 16:9 and
# kept inside the picture. Saves listing\bank-organiser\listing-image.png.
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [int]$X = -1, [int]$Y = -1, [int]$Width = -1, [int]$Height = -1
)
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "listing\bank-organiser\listing-image.png"

$image = [Drawing.Image]::FromFile((Resolve-Path $Source))
try {
    if ($Width -le 0) { $Width = [Math]::Min($image.Width, [int]($image.Height * 16 / 9)) }
    $Height = [int]($Width * 9 / 16)
    if ($Height -gt $image.Height) { $Height = $image.Height; $Width = [int]($Height * 16 / 9) }
    if ($X -lt 0) { $X = [int](($image.Width - $Width) / 2) }
    if ($Y -lt 0) { $Y = [int](($image.Height - $Height) / 2) }
    $X = [Math]::Max(0, [Math]::Min($X, $image.Width - $Width))
    $Y = [Math]::Max(0, [Math]::Min($Y, $image.Height - $Height))

    $result = New-Object Drawing.Bitmap 1280, 720
    $g = [Drawing.Graphics]::FromImage($result)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($image, (New-Object Drawing.Rectangle 0, 0, 1280, 720), (New-Object Drawing.Rectangle $X, $Y, $Width, $Height), [Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $result.Save($out, [Drawing.Imaging.ImageFormat]::Png)
    $result.Dispose()
} finally {
    $image.Dispose()
}
Write-Host "Saved $out (1280x720 from $Width x $Height at $X,$Y)"
