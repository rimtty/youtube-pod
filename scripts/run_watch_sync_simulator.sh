#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
XCODEGEN="$PROJECT_ROOT/.build/tools/xcodegen-dist/xcodegen/bin/xcodegen"
DERIVED_DATA=${YOUTUBEPOD_WATCH_SYNC_DERIVED_DATA:-/tmp/youtubepod-watch-sync-simulator-derived-data}
DEVICE_NAME=${YOUTUBEPOD_WATCH_SYNC_DEVICE_NAME:-YouTubePod Watch Sync Simulator}
DEVICE_TYPE=${YOUTUBEPOD_WATCH_SYNC_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm}

if [[ ! -x "$XCODEGEN" ]]; then
    print -u2 "Run ./scripts/bootstrap.sh before launching the Watch sync fixture."
    exit 1
fi

runtime_id=$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
for runtime in json.load(sys.stdin).get("runtimes", []):
    if runtime.get("isAvailable") and runtime.get("identifier", "").endswith("watchOS-27-0"):
        print(runtime["identifier"])
        break
')
if [[ -z "$runtime_id" ]]; then
    print -u2 "watchOS 27 Simulator runtime is not installed."
    exit 1
fi

device_id=$(xcrun simctl list devices --json | python3 -c '
import json, sys
name = sys.argv[1]
runtime = sys.argv[2]
devices = json.load(sys.stdin).get("devices", {}).get(runtime, [])
for device in devices:
    if device.get("isAvailable") and device.get("name") == name:
        print(device["udid"])
        break
' "$DEVICE_NAME" "$runtime_id")

if [[ -z "$device_id" ]]; then
    device_id=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$runtime_id")
fi

xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_id" -b

cd "$PROJECT_ROOT"
"$XCODEGEN" generate
xcodebuild build \
    -project YouTubePod.xcodeproj \
    -scheme YouTubePodWatch \
    -destination "platform=watchOS Simulator,id=$device_id" \
    -derivedDataPath "$DERIVED_DATA"

watch_app="$DERIVED_DATA/Build/Products/Debug-watchsimulator/YouTubePodWatch.app"
if [[ ! -d "$watch_app" ]]; then
    print -u2 "Watch app was not produced at $watch_app"
    exit 1
fi

xcrun simctl install "$device_id" "$watch_app"
open -a Simulator --args -CurrentDeviceUDID "$device_id"
xcrun simctl launch --terminate-running-process \
    "$device_id" \
    com.rimtty.YouTubePod.watchkitapp \
    --watch-sync-simulator-fixture

print "Watch sync Simulator fixture launched."
print "Device: $DEVICE_NAME ($device_id)"
print "The library starts empty, then imports a generated M4A after about two seconds."
print "Only the unsupported WCSession file-delivery boundary is simulated."
