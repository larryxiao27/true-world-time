#!/bin/bash
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_DERIVED="${TWT_DERIVED_DATA:-/private/tmp/true-world-time-release-derived}"
python3 "$PROBE_ROOT/scripts/generate-project.py"
mkdir -p "$PROBE_ROOT/dist" "$PROBE_ROOT/evidence"
if xcodebuild -checkFirstLaunchStatus > "$PROBE_ROOT/evidence/xcode-first-launch.log" 2>&1; then
    xcodebuild -project "$PROBE_ROOT/TrueWorldTimeProbe.xcodeproj" -scheme TrueWorldTimeProbe -configuration Release -derivedDataPath "$PROBE_DERIVED" -destination 'platform=macOS,arch=arm64' build > "$PROBE_ROOT/evidence/xcode-build.log" 2>&1
    PROBE_APP="$PROBE_DERIVED/Build/Products/Release/TrueWorldTimeProbe.app"
else
    printf '%s\n' 'Xcode first-launch components are incomplete; using the installed Swift compiler with the standard app-extension entry point.'
    TWT_BUILD_DIR="$PROBE_DERIVED/Standalone" bash "$PROBE_ROOT/scripts/build-probe.sh" > "$PROBE_ROOT/evidence/compiler-build.log" 2>&1
    PROBE_APP="$PROBE_DERIVED/Standalone/TrueWorldTimeProbe.app"
fi
codesign --verify --deep --strict "$PROBE_APP"
PROBE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROBE_APP/Contents/Info.plist")"
ditto -c -k --keepParent --norsrc "$PROBE_APP" "$PROBE_ROOT/dist/TrueWorldTime-$PROBE_VERSION.zip"
printf '%s\n' "$PROBE_ROOT/dist/TrueWorldTime-$PROBE_VERSION.zip"
bash "$PROBE_ROOT/scripts/make-dmg.sh" "$PROBE_APP" "$PROBE_ROOT/dist/TrueWorldTime-$PROBE_VERSION.dmg"
