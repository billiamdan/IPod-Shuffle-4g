#!/bin/bash
# Builds dist/Shuffler.app and dist/Shuffler-<version>.dmg.
#
#   scripts/build-app.sh
#
# Settings (environment variables):
#   VERSION         version shown in Finder                      (default 2.0.0)
#   ARCHS           architectures to build                       (default "arm64 x86_64")
#   SIGN_IDENTITY   code-signing identity                        (default "-", ad-hoc: fine on this Mac)
#   NOTARY_PROFILE  notarytool keychain profile; when set the DMG is notarized and stapled,
#                   which needs a "Developer ID Application" identity in SIGN_IDENTITY
#   BUNDLE_ID       bundle identifier                            (default io.github.billiamdan.shuffler)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Shuffler"
VERSION="${VERSION:-2.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.billiamdan.shuffler}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64 x86_64}"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$DIST/dmg-staging"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "==> Building ($ARCHS)"
swift build -c release "${arch_flags[@]}" --product Shuffler
swift build -c release "${arch_flags[@]}" --product shufflectl
BIN="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

echo "==> Assembling $APP"
mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME.app" "$DIST/dmg-staging" "$DIST/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Shuffler" "$APP/Contents/MacOS/Shuffler"
# The command-line tool rides along: Shuffler.app/Contents/MacOS/shufflectl
cp "$BIN/shufflectl" "$APP/Contents/MacOS/shufflectl"

swift scripts/make-icon.swift "$DIST/AppIcon.iconset"
iconutil -c icns "$DIST/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$DIST/AppIcon.iconset"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Shuffler</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Shuffler reads and updates the music, playlists and VoiceOver recordings on your iPod.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Shuffler copies the songs you choose to your iPod.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Shuffler copies the songs you choose to your iPod.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Shuffler copies the songs you choose to your iPod.</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>io.github.billiamdan.shuffler.tracks</string>
            <key>UTTypeDescription</key><string>Shuffler tracks</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Signing ($SIGN_IDENTITY)"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/shufflectl"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Building $DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
if diskutil image create from --help >/dev/null 2>&1; then
    # macOS 26 and later: hdiutil's image creation is deprecated in favour of diskutil.
    diskutil image create from --format UDZO --volumeName "$APP_NAME" "$STAGE" "$DMG" >/dev/null
else
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
fi
rm -rf "$DIST/dmg-staging"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "==> Done"
ls -lh "$DMG"
lipo -archs "$APP/Contents/MacOS/Shuffler" | sed 's/^/    architectures: /'
