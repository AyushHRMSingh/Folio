#!/bin/zsh
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns (needs Inkscape: brew install --cask inkscape).
# The tile is placed on Apple's icon grid: 824×824 inside a transparent 1024 canvas, like other macOS app icons.
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="$ROOT/Resources/AppIcon.svg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
INNER="$(sed -e '1d' -e '$d' "$SRC")"
cat > "$WORK/grid.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<g transform="translate(100 100) scale(0.8046875)">
$INNER
</g>
</svg>
SVG
SET="$WORK/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  inkscape "$WORK/grid.svg" --export-type=png --export-filename="$SET/icon_${s}x${s}.png" -w $s -h $s >/dev/null 2>&1
  d=$((s * 2))
  inkscape "$WORK/grid.svg" --export-type=png --export-filename="$SET/icon_${s}x${s}@2x.png" -w $d -h $d >/dev/null 2>&1
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
cp "$SET/icon_512x512@2x.png" "$ROOT/Resources/AppIcon-1024.png"
echo "Wrote $ROOT/Resources/AppIcon.icns"
