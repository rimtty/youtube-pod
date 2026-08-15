#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DESTINATION=${YOUTUBEPOD_WATCH_DESTINATION:-platform=watchOS Simulator,OS=latest,name=Apple Watch Series 9 (45mm)}
DERIVED_DATA=${YOUTUBEPOD_WATCH_DERIVED_DATA:-/tmp/youtubepod-watch-verify-derived-data}
XCODEGEN="$PROJECT_ROOT/.build/tools/xcodegen-dist/xcodegen/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]]; then
    print -u2 "Run ./scripts/bootstrap.sh before verification."
    exit 1
fi

cd "$PROJECT_ROOT"
"$XCODEGEN" generate

xcodebuild test \
    -project YouTubePod.xcodeproj \
    -scheme YouTubePodWatch \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA"
