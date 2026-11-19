#!/bin/zsh
# Builds Folio.app into ~/Applications (no admin needed).
set -euo pipefail
cd "${0:A:h}"

swift build -c release --product FolioApp
BIN="$(swift build -c release --show-bin-path)"

APP="$HOME/Applications/Folio.app"
# A running copy keeps using the old binary; close it (it saves on a normal quit) and reopen afterwards.
WAS_RUNNING=0
if pgrep -f "$APP/Contents/MacOS/Folio" >/dev/null; then
  WAS_RUNNING=1
  pkill -TERM -f "$APP/Contents/MacOS/Folio" || true
  for i in {1..10}; do pgrep -f "$APP/Contents/MacOS/Folio" >/dev/null || break; sleep 1; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/FolioApp" "$APP/Contents/MacOS/Folio"
mkdir -p "$APP/Contents/Resources"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"     # regenerate with Tools/make-icon.sh

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.folio.reader</string>
  <key>CFBundleName</key><string>Folio</string>
  <key>CFBundleDisplayName</key><string>Folio</string>
  <key>CFBundleExecutable</key><string>Folio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Installed: $APP"
if [ "$WAS_RUNNING" = 1 ]; then open "$APP"; fi
