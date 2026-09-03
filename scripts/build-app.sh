#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_ROOT="$PROJECT_ROOT/dist/Transcribe.app"
STAGING_ROOT="$(mktemp -d)/Transcribe.app"

cleanup() {
    /bin/rm -rf "${STAGING_ROOT:h}"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"
swift build -c release --arch arm64
BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p "$STAGING_ROOT/Contents/MacOS"
mkdir -p "$STAGING_ROOT/Contents/Resources"
cp "$BIN_PATH/Transcribe" "$STAGING_ROOT/Contents/MacOS/Transcribe"
cp "$PROJECT_ROOT/Resources/Info.plist" "$STAGING_ROOT/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/whisper_transcribe.py" "$STAGING_ROOT/Contents/Resources/whisper_transcribe.py"
cp "$PROJECT_ROOT/Resources/whisper_download.py" "$STAGING_ROOT/Contents/Resources/whisper_download.py"

codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "local.transcribe.app"' \
    "$STAGING_ROOT"

mkdir -p "$PROJECT_ROOT/dist"
if [[ -e "$APP_ROOT" ]]; then
    /bin/rm -rf "$APP_ROOT"
fi
mv "$STAGING_ROOT" "$APP_ROOT"

print "Built: $APP_ROOT"
