#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

version="1.0.0"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# Building each architecture separately also works with Command Line Tools only.
swift build -c release --arch arm64
swift build -c release --arch x86_64
CODEXSCHEDULER_APP_DIR="$stage/CodexScheduler.app" zsh scripts/build-app.sh

app="$stage/CodexScheduler.app"
arm="$PWD/.build/arm64-apple-macosx/release"
intel="$PWD/.build/x86_64-apple-macosx/release"
lipo -create "$arm/CodexScheduler" "$intel/CodexScheduler" \
  -output "$app/Contents/MacOS/CodexScheduler"
lipo -create "$arm/SchedulerHelper" "$intel/SchedulerHelper" \
  -output "$app/Contents/Helpers/SchedulerHelper.app/Contents/MacOS/SchedulerHelper"

codesign --force --sign - --identifier com.codexscheduler.helper \
  --requirements '=designated => identifier "com.codexscheduler.helper"' \
  "$app/Contents/Helpers/SchedulerHelper.app"
codesign --force --sign - --identifier com.codexscheduler.app \
  --requirements '=designated => identifier "com.codexscheduler.app"' "$app"
codesign --verify --deep --strict "$app"

mkdir -p dist
archive_name="CodexScheduler-v${version}-macOS-universal.zip"
archive="$PWD/dist/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd dist && shasum -a 256 "$archive_name" > "$archive_name.sha256")
file "$app/Contents/MacOS/CodexScheduler"
file "$app/Contents/Helpers/SchedulerHelper.app/Contents/MacOS/SchedulerHelper"
cat "$archive.sha256"
