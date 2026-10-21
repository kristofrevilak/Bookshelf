#!/bin/bash
# Assembles Bookshelf.app from the SwiftPM executable. SwiftPM builds a bare binary;
# a GUI app needs the bundle layout, an Info.plist and a signature.
set -euo pipefail

CONFIGURATION="${1:-release}"
# Injectable so the release workflow can stamp the git tag into the bundle. A bare local
# run keeps 0.1 (1), so nothing about `./Scripts/make-app.sh` changes.
BOOKSHELF_VERSION="${BOOKSHELF_VERSION:-0.1}"
BOOKSHELF_VERSION="${BOOKSHELF_VERSION#v}"  # tolerate a raw tag name such as v0.2.1
BOOKSHELF_BUILD="${BOOKSHELF_BUILD:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Bookshelf.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product Bookshelf
BINARY="$(swift build -c "$CONFIGURATION" --product Bookshelf --show-bin-path)/Bookshelf"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Bookshelf"

# Committed, not generated here — Scripts/make-icon.swift redraws it when the artwork
# changes. Must land before codesign so the signature seals it.
cp "$ROOT/Resources/Bookshelf.icns" "$APP/Contents/Resources/Bookshelf.icns"

# Unquoted delimiter: the body carries no $, backtick or backslash of its own, so the two
# version substitutions below are the only expansions.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleName</key><string>Bookshelf</string>
    <key>CFBundleDisplayName</key><string>Bookshelf</string>
    <key>CFBundleIdentifier</key><string>com.kristofrevilak.Bookshelf</string>
    <key>CFBundleExecutable</key><string>Bookshelf</string>
    <key>CFBundleIconFile</key><string>Bookshelf</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${BOOKSHELF_VERSION}</string>
    <key>CFBundleVersion</key><string>${BOOKSHELF_BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Sync your calibre library with Kindle e-readers</string>
</dict>
</plist>
PLIST

# A malformed injected version would otherwise get sealed into the signature.
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc by default, which is enough for a locally built app. The release workflow sets
# BOOKSHELF_SIGN_IDENTITY to its Developer ID: notarization then needs the hardened runtime and a
# secure timestamp. USB access needs no entitlement either way — the app is not sandboxed and
# the MTP interface is unclaimed by any system driver.
if [[ -n "${BOOKSHELF_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$BOOKSHELF_SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
fi

echo "$APP ($BOOKSHELF_VERSION build $BOOKSHELF_BUILD)"
du -sh "$APP" | cut -f1 | xargs echo "Size:"
