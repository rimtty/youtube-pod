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

if [[ ! -f "$PROJECT_ROOT/PythonRuntime/site-packages/yt_dlp_ejs/yt/solver/core.min.js" ]]; then
    print -u2 "Bundled yt-dlp-ejs is missing. Run ./scripts/bootstrap.sh before verification."
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

IPHONE_APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/YouTubePod.app"
python3 scripts/verify_privacy_manifests.py \
    --iphone "$IPHONE_APP/PrivacyInfo.xcprivacy" \
    --watch "$IPHONE_APP/Watch/YouTubePodWatch.app/PrivacyInfo.xcprivacy"
