#!/bin/zsh
# Builds dist/Root.app (release, signed with the stable "Parabolic Local Signing" identity; ad-hoc only as a fallback).
# Usage: ./scripts/bundle.sh
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="dist/Root.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Parabolic" "$APP/Contents/MacOS/Root"
# Native-messaging host for the browser extension, and the aria2 file/torrent engine.
cp "$BIN_DIR/ParabolicHost" "$APP/Contents/MacOS/ParabolicHost"
cp vendor/aria2c "$APP/Contents/MacOS/aria2c"
# Unpacked browser extensions (Chromium + Firefox), built from extension/.
if [[ -x scripts/build-extension.sh ]]; then
  ./scripts/build-extension.sh "$APP/Contents/Resources/Extension" >/dev/null
fi

# App icon: render 1024 px, then downsample into a full iconset.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  if [[ $s -ne 512 ]]; then
    sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Root</string>
  <key>CFBundleDisplayName</key><string>Root</string>
  <key>CFBundleIdentifier</key><string>com.hamad.parabolic</string>
  <key>CFBundleExecutable</key><string>Root</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.1</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Root reads the list of apps that open at login from System Events.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.hamad.parabolic</string>
      <key>CFBundleURLSchemes</key>
      <array><string>parabolic</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>Magnet link</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>magnet</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.bittorrent.torrent</string>
      <key>UTTypeDescription</key><string>BitTorrent file</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>torrent</string></array>
        <key>public.mime-type</key><array><string>application/x-bittorrent</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>BitTorrent file</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>org.bittorrent.torrent</string></array>
    </dict>
  </array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>Download with Root</string></dict>
      <key>NSMessage</key><string>downloadFromService</string>
      <key>NSPortName</key><string>Root</string>
      <key>NSSendTypes</key>
      <array>
        <string>public.utf8-plain-text</string>
        <string>NSStringPboardType</string>
      </array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sign with the stable local identity ("Parabolic Local Signing", a self-signed code-signing certificate in the
# login keychain). Its designated requirement is `identifier "com.hamad.parabolic" and certificate leaf = H"<sha1>"`,
# the same on every build, so macOS keeps Full Disk Access, Downloads, Automation and notification permissions
# across rebuilds. Ad-hoc signing ("-") makes a new requirement each build and macOS forgets every permission.
SIGN_ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"Parabolic Local Signing"/ {print $2; exit}')
if [[ -z "$SIGN_ID" ]]; then
  echo "WARNING: 'Parabolic Local Signing' identity not found: signing ad-hoc. Permissions will reset on every build." >&2
  SIGN_ID=-
fi
codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/aria2c" "$APP/Contents/MacOS/ParabolicHost"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP"
