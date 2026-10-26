#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIGURATION="${1:-release}"
if [ ! -f "$ROOT/.build/native/libAltranscribeWhisper.a" ]; then
    bash "$ROOT/macos/scripts/bootstrap-whisper.sh"
fi
swift build --package-path "$ROOT/macos" -c "$CONFIGURATION"
BIN="$(swift build --package-path "$ROOT/macos" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/macos/Altranscribe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Altranscribe" "$APP/Contents/MacOS/Altranscribe"
cp "$ROOT/macos/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/native/whisper-LICENSE" "$APP/Contents/Resources/whisper-LICENSE"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Altranscribe-LICENSE"
cp -R "$ROOT/macos/Resources/Licenses" "$APP/Contents/Resources/"
cp -R "$BIN/Altranscribe_AltranscribeCore.bundle" "$APP/Contents/Resources/"
cp -R "$BIN/FluidAudio_FluidAudio.bundle" "$APP/Contents/Resources/"
install -m 644 "$ROOT/macos/.build/checkouts/FluidAudio/LICENSE" "$APP/Contents/Resources/Licenses/FluidAudio-LICENSE"
mkdir -p "$APP/Contents/Resources/Licenses/FluidAudio"
cp -fR "$ROOT/macos/.build/checkouts/FluidAudio/ThirdPartyLicenses/." "$APP/Contents/Resources/Licenses/FluidAudio/"
for LANGUAGE in en zh-Hans; do
    cp -R "$ROOT/macos/Resources/$LANGUAGE.lproj" "$APP/Contents/Resources/"
done
# Models are installed separately. Remove weights left by older builds, too.
rm -rf "$APP/Contents/Resources/Models"
if [ -f "$ROOT/macos/Resources/AppIcon.icns" ]; then
    cp "$ROOT/macos/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
printf '\nBuilt %s\n' "$APP"
