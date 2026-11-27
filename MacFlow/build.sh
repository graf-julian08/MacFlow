#!/bin/bash
# Builds, signs and (optionally) installs MacFlow.app for Apple Silicon.
#
#   ./build.sh             build into ./release/MacFlow.app
#   ./build.sh --install   also replace /Applications/MacFlow.app and launch it
#
# Signing: a "Developer ID Application" identity is used when available
# (and the app is notarized if NOTARY_PROFILE names a notarytool keychain
# profile); otherwise "Apple Development"; otherwise ad-hoc.
set -euo pipefail

APP_NAME="MacFlow"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$PROJECT_DIR/release"
# Build outside the (possibly synced) project folder: File Provider
# metadata on build products breaks code signatures.
SCRATCH="$HOME/Library/Caches/MacFlow-build"
STAGE="$(mktemp -d /tmp/MacFlow-stage.XXXXXX)"
APP="$STAGE/$APP_NAME.app"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

echo "▸ Compiling (release, arm64)…"
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --scratch-path "$SCRATCH" 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "Sendable" || true
BIN_DIR="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
[[ -x "$BINARY" ]] || { echo "✗ Build failed: $BINARY not found"; exit 1; }

echo "▸ Assembling bundle…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/MacFlow/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/MacFlow/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"
xattr -cr "$APP"

echo "▸ Signing…"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
KIND="Developer ID"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
  KIND="Apple Development"
fi
if [[ -n "$IDENTITY" ]]; then
  echo "  $KIND: $IDENTITY"
  codesign --force --options runtime --timestamp=none --entitlements "$PROJECT_DIR/MacFlow/MacFlow.entitlements" --sign "$IDENTITY" "$APP"
  if [[ "$KIND" == "Developer ID" ]]; then
    codesign --force --options runtime --timestamp --entitlements "$PROJECT_DIR/MacFlow/MacFlow.entitlements" --sign "$IDENTITY" "$APP"
  fi
else
  KIND="ad-hoc"
  echo "  No signing identity found — ad-hoc signature (this Mac only)."
  codesign --force --options runtime --entitlements "$PROJECT_DIR/MacFlow/MacFlow.entitlements" --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

if [[ "$KIND" == "Developer ID" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing (profile $NOTARY_PROFILE)…"
  ditto -c -k --keepParent "$APP" "$STAGE/notarize.zip"
  xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

mkdir -p "$RELEASE_DIR"
rm -rf "$RELEASE_DIR/$APP_NAME.app"
ditto --noextattr --norsrc "$APP" "$RELEASE_DIR/$APP_NAME.app"
echo "$KIND" > "$RELEASE_DIR/.signing-kind"
echo "✓ Built $RELEASE_DIR/$APP_NAME.app  ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"), $KIND, $(du -sh "$APP" | cut -f1))"

if [[ $INSTALL == 1 ]]; then
  echo "▸ Installing to /Applications…"
  osascript -e 'tell application id "com.macflow.app" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  ditto --noextattr --norsrc "$APP" "/Applications/$APP_NAME.app"
  codesign --verify --strict "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "✓ Installed and launched /Applications/$APP_NAME.app"
fi
rm -rf "$STAGE"
