#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DERIVED_DATA_ROOT=${YOUTUBEPOD_WATCH_DERIVED_DATA:-/tmp/youtubepod-watch-verify-derived-data}
RESULTS_BASE=${YOUTUBEPOD_WATCH_RESULTS:-/tmp/youtubepod-watch-verify-results}
BOOT_TIMEOUT_SECONDS=${YOUTUBEPOD_WATCH_BOOT_TIMEOUT_SECONDS:-300}
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RESULTS_ROOT="$RESULTS_BASE/$RUN_ID"
XCODEGEN="$PROJECT_ROOT/.build/tools/xcodegen-dist/xcodegen/bin/xcodegen"

typeset -a CREATED_DEVICE_IDS=()

cleanup_created_devices() {
    local device_id
    for device_id in "${CREATED_DEVICE_IDS[@]}"; do
        xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
        xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
    done
}

trap cleanup_created_devices EXIT INT TERM

if [[ ! -x "$XCODEGEN" ]]; then
    print -u2 "Run ./scripts/bootstrap.sh before verification."
    exit 1
fi

watch_runtime_id() {
    xcrun simctl list runtimes available -j | python3 -c '
import json
import re
import sys

runtimes = [
    runtime for runtime in json.load(sys.stdin).get("runtimes", [])
    if runtime.get("name", "").startswith("watchOS 27")
]

def version_key(runtime):
    return tuple(int(part) for part in re.findall(r"\d+", runtime.get("version", "")))

if runtimes:
    print(max(runtimes, key=version_key)["identifier"])
'
}

create_and_boot_watch_device() {
    local device_name=$1
    local device_type=$2
    local runtime_id=$3

    CREATED_DEVICE_ID=$(xcrun simctl create "$device_name" "$device_type" "$runtime_id")
    CREATED_DEVICE_IDS+=("$CREATED_DEVICE_ID")
    xcrun simctl boot "$CREATED_DEVICE_ID"
    DEVICE_ID="$CREATED_DEVICE_ID" BOOT_TIMEOUT_SECONDS="$BOOT_TIMEOUT_SECONDS" python3 -c '
import os
import subprocess
import sys

device_id = os.environ["DEVICE_ID"]
timeout = float(os.environ["BOOT_TIMEOUT_SECONDS"])
try:
    subprocess.run(
        ["xcrun", "simctl", "bootstatus", device_id, "-b"],
        check=True,
        timeout=timeout,
    )
except subprocess.TimeoutExpired:
    print(
        f"Apple Watch Simulator {device_id} did not finish booting within {timeout:g}s.",
        file=sys.stderr,
    )
    raise SystemExit(124)
'
}

run_watch_unit_tests() {
    local destination=$1
    local derived_data=$2
    local result_prefix=$3
    local unit_result="$RESULTS_ROOT/$result_prefix-unit.xcresult"

    print "Testing Watch unit target: $destination"
    xcodebuild test \
        -project YouTubePod.xcodeproj \
        -scheme YouTubePodWatch \
        -destination "$destination" \
        -destination-timeout 180 \
        -derivedDataPath "$derived_data" \
        -resultBundlePath "$unit_result" \
        -parallel-testing-enabled NO
}

run_watch_ui_tests() {
    local destination=$1
    local derived_data=$2
    local result_prefix=$3
    local ui_result="$RESULTS_ROOT/$result_prefix-ui.xcresult"

    print "Testing Watch UI target: $destination"
    xcodebuild test \
        -project YouTubePod.xcodeproj \
        -scheme YouTubePodWatchUI \
        -destination "$destination" \
        -destination-timeout 180 \
        -derivedDataPath "$derived_data" \
        -resultBundlePath "$ui_result" \
        -parallel-testing-enabled NO

    python3 scripts/verify_privacy_manifests.py \
        --iphone YouTubePod/PrivacyInfo.xcprivacy \
        --watch "$derived_data/Build/Products/Debug-watchsimulator/YouTubePodWatch.app/PrivacyInfo.xcprivacy"
}

cd "$PROJECT_ROOT"
mkdir -p "$RESULTS_ROOT"
"$XCODEGEN" generate

if [[ -n ${YOUTUBEPOD_WATCH_DESTINATION:-} ]]; then
    run_watch_unit_tests "$YOUTUBEPOD_WATCH_DESTINATION" "$DERIVED_DATA_ROOT" "custom"
    run_watch_ui_tests "$YOUTUBEPOD_WATCH_DESTINATION" "$DERIVED_DATA_ROOT" "custom"
    print "Watch test result bundles: $RESULTS_ROOT"
    exit 0
fi

runtime_id=$(watch_runtime_id)
if [[ -z "$runtime_id" ]]; then
    print -u2 "watchOS 27 Simulator runtime is not installed."
    exit 1
fi

typeset -A SERIES_9_DEVICE_TYPES=(
    "41mm" "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-41mm"
    "45mm" "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm"
)

for size in 41mm 45mm; do
    device_name="YouTubePod Apple Watch Series 9 ($size) $RUN_ID"
    create_and_boot_watch_device \
        "$device_name" \
        "${SERIES_9_DEVICE_TYPES[$size]}" \
        "$runtime_id"
    device_id=$CREATED_DEVICE_ID
    destination="platform=watchOS Simulator,id=$device_id"
    # Unit tests do not depend on display size. Run them once, then keep UI
    # coverage on both sizes while sharing build products across destinations.
    if [[ "$size" == "41mm" ]]; then
        run_watch_unit_tests "$destination" "$DERIVED_DATA_ROOT" "$size"
    fi
    run_watch_ui_tests "$destination" "$DERIVED_DATA_ROOT" "$size"
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
done

print "Watch test result bundles: $RESULTS_ROOT"
