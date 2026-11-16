# Builds the addon icons in Icons\ from Art\clock.png with ImageMagick.
# Run from anywhere: pwsh Art\make-icons.ps1
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'clock.png'
$icons = Join-Path $PSScriptRoot '..\Icons'
New-Item -ItemType Directory -Force $icons | Out-Null

# The source is 1752x897. The digits are centred near (885, 440) and are 760 px wide, so an
# 840 px square is the tightest crop that keeps all of "00:00" with a margin.
$crop = '840x840+465+20'

# WoW textures need power-of-two sides. 64 is drawn in the addon list and on the minimap button,
# the larger ones in window headers.
foreach ($size in 32, 64, 128, 256) {
  $target = Join-Path $icons "Logo$size.png"
  # Small sizes lose the gaps between the digit segments without sharpening
  $sharpen = if ($size -le 64) { '0x0.8' } else { '0x0.4' }
  magick $source -crop $crop +repage -filter Lanczos -resize "${size}x${size}" `
    -unsharp $sharpen -strip -define png:color-type=2 $target
  if ($LASTEXITCODE -ne 0) { throw "magick failed for $target" }
}
