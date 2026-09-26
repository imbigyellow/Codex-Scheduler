#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="${CODEXSCHEDULER_APP_DIR:-$PWD/build/CodexScheduler.app}"
mkdir -p "$app_dir/Contents/MacOS"
helper_app="$app_dir/Contents/Helpers/SchedulerHelper.app"
mkdir -p "$helper_app/Contents/MacOS"
cp "$bin_dir/CodexScheduler" "$app_dir/Contents/MacOS/CodexScheduler"
rm -f "$app_dir/Contents/MacOS/SchedulerHelper"
cp "$bin_dir/SchedulerHelper" "$helper_app/Contents/MacOS/SchedulerHelper"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Codex Scheduler</string>
<key>CFBundleDisplayName</key><string>Codex Scheduler</string>
<key>CFBundleIdentifier</key><string>com.codexscheduler.app</string>
<key>CFBundleExecutable</key><string>CodexScheduler</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$helper_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SchedulerHelper</string>
<key>CFBundleDisplayName</key><string>SchedulerHelper</string>
<key>CFBundleIdentifier</key><string>com.codexscheduler.helper</string>
<key>CFBundleExecutable</key><string>SchedulerHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.codexscheduler.helper \
  --requirements '=designated => identifier "com.codexscheduler.helper"' "$helper_app"
codesign --force --sign - --identifier com.codexscheduler.app \
  --requirements '=designated => identifier "com.codexscheduler.app"' "$app_dir"
echo "$app_dir"
