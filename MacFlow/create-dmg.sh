#!/bin/bash
# Packages release/MacFlow.app into a drag-to-install disk image.
# Run ./build.sh first. With a Developer ID identity and NOTARY_PROFILE set,
# the DMG is signed and notarized as well.
set -euo pipefail

APP_NAME="MacFlow"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIR/release/$APP_NAME-$VERSION.dmg"
STAGE="$(mktemp -d /tmp/MacFlow-dmg.XXXXXX)"
KIND="$(cat "$DIR/release/.signing-kind" 2>/dev/null || echo unknown)"

[[ -d "$APP" ]] || { echo "✗ $APP not found — run ./build.sh first."; exit 1; }
# The project folder may be synced; File Provider metadata is not part of the
# signature, so verify a clean copy.
ditto --noextattr --norsrc "$APP" "$STAGE/$APP_NAME.app"
xattr -cr "$STAGE/$APP_NAME.app"
codesign --verify --strict "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

if [[ "$KIND" == "Developer ID" ]]; then
  OPEN_NOTE="Double-click MacFlow in Applications. It is signed and notarized by Apple."
else
  OPEN_NOTE="This copy is not notarized by Apple, so macOS asks once:
   • Double-click MacFlow in Applications. If macOS says it cannot verify
     the developer, click “Done”.
   • Open System Settings → Privacy & Security, scroll down and click
     “Open Anyway” next to MacFlow, then confirm with “Open”.
   macOS remembers this; you only do it once."
fi

cat > "$STAGE/Read Me.txt" <<README
MacFlow $VERSION — convert, edit and act on files right from a drag
=====================================================================

INSTALL
1. Drag MacFlow onto the Applications folder in this window.
2. $OPEN_NOTE
3. MacFlow lives in the menu bar (circle icon). It opens automatically at
   login; you can change that in Settings → General.

USE
Start dragging any file or folder in Finder or on the Desktop, then hold:
   ⇧ Shift     Convert to another format
   ⌘ Command   File tools (compress, metadata, edit, crop, rotate, …)
   ⌃ Control   File actions (AirDrop, Float, Copy, Move, Copy Path, Terminal)
The wheel stays open — let go of the key, move onto a segment and drop.
Dropping anywhere else does nothing. Results are new files next to the
original; originals are never changed and nothing is ever overwritten.

REQUIREMENTS
• Apple silicon Mac, macOS 15 or later (Liquid Glass on macOS 26+).
• No permissions are required. Optional: Accessibility for arrow-key
  navigation inside the wheel.
• Optional helpers you may install yourself (e.g. Homebrew) for extra
  formats: FFmpeg (MKV, WebM, AVI, MP3/Opus output), cwebp (WebP output).
  MacFlow never downloads anything.

PRIVACY
Everything runs locally. MacFlow makes no network connections.
README

rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ "$KIND" == "Developer ID" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

# Verify the app inside the image.
MNT="$(mktemp -d /tmp/MacFlow-verify.XXXXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
codesign --verify --strict "$MNT/$APP_NAME.app"
hdiutil detach "$MNT" >/dev/null
echo "✓ $DMG ($(du -h "$DMG" | cut -f1), $KIND)"
