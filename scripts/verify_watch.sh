#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DERIVED_DATA=${YOUTUBEPOD_WATCH_DERIVED_DATA:-/tmp/youtubepod-watch-verify-derived-data}
XCODEGEN="$PROJECT_ROOT/.build/tools/xcodegen-dist/xcodegen/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]]; then
    print -u2 "Run ./scripts/bootstrap.sh before verification."
    exit 1
fi

if [[ -n ${YOUTUBEPOD_WATCH_DESTINATION:-} ]]; then
    DESTINATION=$YOUTUBEPOD_WATCH_DESTINATION
else
    WATCH_DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c '
import json
import sys

preferred_names = [
    "Apple Watch Series 9 (45mm)",
    "Apple Watch Series 9 (41mm)",
    "Apple Watch Series 10 (46mm)",
    "Apple Watch Series 10 (42mm)",
    "Apple Watch Series 11 (46mm)",
    "Apple Watch Series 11 (42mm)",
    "Apple Watch Ultra 2 (49mm)",
    "Apple Watch Ultra 3 (49mm)",
]
devices = [
    device
    for runtime_devices in json.load(sys.stdin).get("devices", {}).values()
    for device in runtime_devices
]
by_name = {device.get("name"): device.get("udid") for device in devices}
for name in preferred_names:
    if by_name.get(name):
        print(by_name[name])
        break
')
    if [[ -z "$WATCH_DEVICE_ID" ]]; then
        print -u2 "No Apple Watch Series 9 or newer simulator is available."
        xcrun simctl list devices available
        exit 1
    fi
    DESTINATION="platform=watchOS Simulator,id=$WATCH_DEVICE_ID"
fi

cd "$PROJECT_ROOT"
"$XCODEGEN" generate

print "Testing Watch destination: $DESTINATION"

xcodebuild test \
    -project YouTubePod.xcodeproj \
    -scheme YouTubePodWatch \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA"
