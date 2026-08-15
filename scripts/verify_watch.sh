#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DERIVED_DATA_ROOT=${YOUTUBEPOD_WATCH_DERIVED_DATA:-/tmp/youtubepod-watch-verify-derived-data}
XCODEGEN="$PROJECT_ROOT/.build/tools/xcodegen-dist/xcodegen/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]]; then
    print -u2 "Run ./scripts/bootstrap.sh before verification."
    exit 1
fi

watch_device_id() {
    local device_name=$1
    xcrun simctl list devices available -j | DEVICE_NAME="$device_name" python3 -c '
import json
import os
import sys
devices = [
    device
    for runtime_devices in json.load(sys.stdin).get("devices", {}).values()
    for device in runtime_devices
]
for device in devices:
    if device.get("name") == os.environ["DEVICE_NAME"]:
        print(device.get("udid", ""))
        break
'
}

create_watch_device() {
    local device_name=$1
    local device_type=$2
    local runtime_id
    runtime_id=$(xcrun simctl list runtimes available -j | python3 -c '
import json
import sys
runtimes = [
    runtime for runtime in json.load(sys.stdin).get("runtimes", [])
    if runtime.get("name", "").startswith("watchOS 27")
]
if runtimes:
    print(sorted(runtimes, key=lambda value: value.get("version", ""))[-1]["identifier"])
')
    if [[ -z "$runtime_id" ]]; then
        print -u2 "watchOS 27 Simulator runtime is not installed."
        exit 1
    fi
    xcrun simctl create "$device_name" "$device_type" "$runtime_id"
}

run_watch_tests() {
    local destination=$1
    local derived_data=$2
    print "Testing Watch destination: $destination"
    xcodebuild test \
        -project YouTubePod.xcodeproj \
        -scheme YouTubePodWatch \
        -destination "$destination" \
        -derivedDataPath "$derived_data"

    python3 scripts/verify_privacy_manifests.py \
        --iphone YouTubePod/PrivacyInfo.xcprivacy \
        --watch "$derived_data/Build/Products/Debug-watchsimulator/YouTubePodWatch.app/PrivacyInfo.xcprivacy"
}

cd "$PROJECT_ROOT"
"$XCODEGEN" generate

if [[ -n ${YOUTUBEPOD_WATCH_DESTINATION:-} ]]; then
    run_watch_tests "$YOUTUBEPOD_WATCH_DESTINATION" "$DERIVED_DATA_ROOT"
    exit 0
fi

typeset -A SERIES_9_DEVICE_TYPES=(
    "41mm" "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-41mm"
    "45mm" "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm"
)

for size in 41mm 45mm; do
    device_name="YouTubePod Apple Watch Series 9 ($size)"
    device_id=$(watch_device_id "$device_name")
    if [[ -z "$device_id" ]]; then
        device_id=$(create_watch_device "$device_name" "${SERIES_9_DEVICE_TYPES[$size]}")
    fi
    run_watch_tests \
        "platform=watchOS Simulator,id=$device_id" \
        "$DERIVED_DATA_ROOT-$size"
done
