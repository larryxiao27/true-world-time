#!/bin/bash
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_BUILD="${TWT_BUILD_DIR:-/private/tmp/true-world-time-release-build}"
PROBE_APP="$PROBE_BUILD/TrueWorldTimeProbe.app"
PROBE_WIDGET="$PROBE_APP/Contents/PlugIns/TrueWorldTimeWidget.appex"
PROBE_SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_WIDGET/Contents/MacOS" "$PROBE_BUILD/module-cache" "$PROBE_ROOT/evidence"
export CLANG_MODULE_CACHE_PATH="$PROBE_BUILD/module-cache"
# Match Xcode's com.apple.product-type.app-extension LD_ENTRY_POINT.
# Swift @main is invoked inside the extension lifecycle, not as the process entry.
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx15.0 -sdk "$PROBE_SDK" -module-cache-path "$PROBE_BUILD/module-cache" -module-name TrueWorldTimeWidget -application-extension -Xlinker -e -Xlinker _NSExtensionMain "$PROBE_ROOT/Sources/ClockCore/ClockCore.swift" "$PROBE_ROOT/Widget/TrueWorldTimeWidget.swift" -o "$PROBE_WIDGET/Contents/MacOS/TrueWorldTimeWidget"
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx15.0 -sdk "$PROBE_SDK" -module-cache-path "$PROBE_BUILD/module-cache" -module-name TrueWorldTime "$PROBE_ROOT/Sources/ClockCore/ClockCore.swift" "$PROBE_ROOT"/AppSupport/*.swift "$PROBE_ROOT/App/TrueWorldTimeProbe.swift" -o "$PROBE_APP/Contents/MacOS/TrueWorldTime"
ditto "$PROBE_ROOT/Resources" "$PROBE_APP/Contents/Resources"
python3 "$PROBE_ROOT/scripts/bundle-info.py" "$PROBE_ROOT" "$PROBE_BUILD"
codesign --force --sign - --entitlements "$PROBE_ROOT/Config/Widget.entitlements" "$PROBE_WIDGET"
codesign --force --sign - "$PROBE_APP"
codesign --verify --deep --strict "$PROBE_APP"
printf '%s\n' "$PROBE_APP"
