#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DESTINATION=${YOUTUBEPOD_DESTINATION:-platform=iOS Simulator,OS=latest,name=iPhone 17 Pro}
DERIVED_DATA=${YOUTUBEPOD_DERIVED_DATA:-/tmp/youtubepod-verify-derived-data}
XCODEGEN="$PROJECT_ROOT/.build/tools/xcodegen-dist/xcodegen/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]]; then
    print -u2 "Run ./scripts/bootstrap.sh before verification."
    exit 1
fi

cd "$PROJECT_ROOT"
python3 -c 'compile(open("PythonRuntime/download_audio.py", encoding="utf-8").read(), "PythonRuntime/download_audio.py", "exec")'

"$XCODEGEN" generate

if [[ ${YOUTUBEPOD_RUN_NETWORK_INTEGRATION:-0} == 1 ]]; then
    SCHEME=YouTubePodIntegration
else
    SCHEME=YouTubePod
fi

xcodebuild test \
    -project YouTubePod.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    "YOUTUBEPOD_TEST_SHORTS_URL=${YOUTUBEPOD_TEST_SHORTS_URL:-}" \
    "YOUTUBEPOD_TEST_LONG_URL=${YOUTUBEPOD_TEST_LONG_URL:-}" \
    "YOUTUBEPOD_TEST_CANCEL_URL=${YOUTUBEPOD_TEST_CANCEL_URL:-}"
