#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON_ARCHIVE="$PROJECT_ROOT/Frameworks/Python-3.14-iOS-support.b10.tar.gz"
PYTHON_URL="https://github.com/beeware/Python-Apple-support/releases/download/3.14-b10/Python-3.14-iOS-support.b10.tar.gz"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
TOOLS_DIR="$PROJECT_ROOT/.build/tools"
XCODEGEN_DIR="$TOOLS_DIR/xcodegen-dist/xcodegen"

mkdir -p "$PROJECT_ROOT/Frameworks" "$PROJECT_ROOT/PythonRuntime/site-packages" "$TOOLS_DIR"

if [ ! -d "$PROJECT_ROOT/Frameworks/Python.xcframework" ]; then
  curl -fL "$PYTHON_URL" -o "$PYTHON_ARCHIVE"
  tar -xzf "$PYTHON_ARCHIVE" -C "$PROJECT_ROOT/Frameworks"
fi

install_python_packages() {
  "$@" \
    --no-compile \
    --no-deps \
    --upgrade \
    --target "$PROJECT_ROOT/PythonRuntime/site-packages" \
    --requirement "$PROJECT_ROOT/PythonRuntime/requirements.lock"
}

if command -v uv >/dev/null 2>&1; then
  install_python_packages uv pip install --python 3.13
else
  python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else "Python 3.10+ or uv is required to build the bundled packages.")'
  install_python_packages python3 -m pip install --disable-pip-version-check
fi

# Local fixes for vendored packages (see PythonRuntime/patches/README.md).
# Must run after every install: --upgrade replaces the patched files.
python3 "$PROJECT_ROOT/scripts/patch_python_runtime.py"

if [ ! -x "$XCODEGEN_DIR/bin/xcodegen" ]; then
  curl -fL "$XCODEGEN_URL" -o "$TOOLS_DIR/xcodegen.zip"
  unzip -qo "$TOOLS_DIR/xcodegen.zip" -d "$TOOLS_DIR/xcodegen-dist"
  chmod +x "$XCODEGEN_DIR/bin/xcodegen"
fi

cd "$PROJECT_ROOT"
"$XCODEGEN_DIR/bin/xcodegen" generate
echo "Bootstrap complete. Open $PROJECT_ROOT/YouTubePod.xcodeproj"
