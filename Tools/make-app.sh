#!/bin/zsh
# Builds PS5Stream and wraps it in an app bundle (needed for controller haptics and microphone access).
# Usage: Tools/make-app.sh   ->   build/PS5Stream.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/PS5Stream.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PS5Stream "$APP/Contents/MacOS/PS5Stream"
# Keep the executable's UUID the same on every build so macOS remembers Local Network access.
python3 Tools/pin-uuid.py "$APP/Contents/MacOS/PS5Stream" local.ps5stream.player

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.ps5stream.player</string>
    <key>CFBundleName</key><string>PS5Stream</string>
    <key>CFBundleExecutable</key><string>PS5Stream</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Your voice is sent to the PS5 for party and game chat when you unmute with M.</string>
    <key>NSLocalNetworkUsageDescription</key><string>PS5Stream connects to your PS5 on the local network.</string>
    <key>GCSupportsControllerUserInteraction</key><true/>
    <key>GCSupportsGameMode</key><true/>
</dict>
</plist>
PLIST

# Sign with the first Apple Development identity if there is one: a stable signature means macOS
# remembers Local Network and microphone permissions across rebuilds. Falls back to ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --entitlements /dev/stdin "$APP" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT
echo "built $APP"
