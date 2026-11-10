#!/bin/bash
set -euo pipefail
PROBE_APP="$1"
PROBE_IMAGE="$2"
PROBE_STAGING="$(mktemp -d /private/tmp/true-world-time-image.XXXXXX)"
trap 'rm -rf "$PROBE_STAGING"' EXIT
ditto --norsrc "$PROBE_APP" "$PROBE_STAGING/TrueWorldTimeProbe.app"
ln -s /Applications "$PROBE_STAGING/Applications"
codesign --verify --deep --strict "$PROBE_STAGING/TrueWorldTimeProbe.app"
hdiutil create -volname '我的时区' -srcfolder "$PROBE_STAGING" -format UDZO -ov "$PROBE_IMAGE"
hdiutil verify "$PROBE_IMAGE"
