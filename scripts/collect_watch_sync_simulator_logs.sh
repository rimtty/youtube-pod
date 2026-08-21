#!/bin/zsh
set -euo pipefail

MINUTES=${1:-15}
DEVICE_ID=${YOUTUBEPOD_WATCH_LOG_DEVICE_ID:-}
OUTPUT=${YOUTUBEPOD_WATCH_LOG_OUTPUT:-/tmp/youtubepod-watch-sync-$(date +%Y%m%d-%H%M%S).log}

if [[ ! "$MINUTES" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Usage: $0 [positive-minutes]"
    exit 2
fi

if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID=$(xcrun simctl list devices --json | python3 -c '
import json
import sys

for runtime, devices in json.load(sys.stdin).get("devices", {}).items():
    if "watchOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("state") == "Booted":
            print(device["udid"])
            raise SystemExit
')
fi

if [[ -z "$DEVICE_ID" ]]; then
    print -u2 "No booted Apple Watch Simulator was found."
    print -u2 "Launch one with ./scripts/run_watch_sync_simulator.sh first."
    exit 1
fi

xcrun simctl spawn "$DEVICE_ID" log show \
    --last "${MINUTES}m" \
    --style compact \
    --predicate 'subsystem == "com.rimtty.YouTubePod.watch-sync"' \
    > "$OUTPUT"

print "Watch sync logs: $OUTPUT"
print "Simulator: $DEVICE_ID"
