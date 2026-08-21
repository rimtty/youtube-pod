#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
DERIVED_DATA=${YOUTUBEPOD_WATCH_RELEASE_DERIVED_DATA:-/tmp/youtubepod-watch-release-isolation-$RUN_ID}
XCODEGEN="$PROJECT_ROOT/.build/tools/xcodegen-dist/xcodegen/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]]; then
    print -u2 "Run ./scripts/bootstrap.sh before verification."
    exit 1
fi

cd "$PROJECT_ROOT"
"$XCODEGEN" generate

build_settings=$(xcodebuild \
    -project YouTubePod.xcodeproj \
    -target YouTubePodWatch \
    -configuration Release \
    -sdk watchsimulator \
    -showBuildSettings)

release_conditions=$(print -r -- "$build_settings" | awk '
    /^[[:space:]]*(SWIFT_ACTIVE_COMPILATION_CONDITIONS|GCC_PREPROCESSOR_DEFINITIONS)[[:space:]]*=/ {
        print
    }
')

if print -r -- "$release_conditions" | grep -Eq '(^|[[:space:]=])DEBUG([[:space:]=]|$)'; then
    print -u2 "Release Watch build unexpectedly defines DEBUG:"
    print -u2 -- "$release_conditions"
    exit 1
fi

xcodebuild build \
    -project YouTubePod.xcodeproj \
    -scheme YouTubePodWatch \
    -configuration Release \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath "$DERIVED_DATA"

watch_app="$DERIVED_DATA/Build/Products/Release-watchsimulator/YouTubePodWatch.app"
if [[ ! -d "$watch_app" ]]; then
    print -u2 "Release Watch app was not produced at $watch_app"
    exit 1
fi

leaked_test_assets=$(find "$watch_app" \( -type d -name '*.xctest' -o -type f -name '*.m4a' \) -print)
if [[ -n "$leaked_test_assets" ]]; then
    print -u2 "Release Watch app contains UI-test bundles or M4A fixtures:"
    print -u2 -- "$leaked_test_assets"
    exit 1
fi

watch_executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$watch_app/Info.plist")
watch_executable="$watch_app/$watch_executable_name"
if [[ ! -f "$watch_executable" ]]; then
    print -u2 "Release Watch executable was not found at $watch_executable"
    exit 1
fi

typeset -a fixture_sentinels=(
    '--watch-ui-test-fixture'
    '--watch-ui-test-accessibility-size'
    '--watch-ui-test-reduce-motion'
    'WatchUITestFixture'
    'YOUTUBEPOD_WATCH_UI_FIXTURE_SENTINEL'
    'uitest00001'
    'uitest00002'
    'watch.motion.probe'
)

if [[ -n ${YOUTUBEPOD_WATCH_FIXTURE_SENTINELS:-} ]]; then
    fixture_sentinels+=("${(@s:,:)YOUTUBEPOD_WATCH_FIXTURE_SENTINELS}")
fi

for sentinel in "${fixture_sentinels[@]}"; do
    if strings -a "$watch_executable" | grep -F -- "$sentinel" >/dev/null; then
        print -u2 "Release Watch executable contains UI-test fixture sentinel: $sentinel"
        exit 1
    fi
done

print "Watch Release isolation verification passed."
print "Release Watch app: $watch_app"
