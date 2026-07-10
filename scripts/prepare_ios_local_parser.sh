#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_ROOT="$PROJECT_ROOT/client/ios"
PYTHON_SUPPORT_URL="${PYTHON_SUPPORT_URL:-https://github.com/beeware/Python-Apple-support/releases/download/3.14-b10/Python-3.14-iOS-support.b10.tar.gz}"
YTDLP_VERSION="${YTDLP_VERSION:-2026.7.4}"
ARCHIVE="$(mktemp -t langbai-python-ios.XXXXXX.tar.gz)"

cleanup() {
  rm -f "$ARCHIVE"
}
trap cleanup EXIT

curl --fail --location --retry 3 "$PYTHON_SUPPORT_URL" --output "$ARCHIVE"

FRAMEWORK_TARGET="$IOS_ROOT/Python.xcframework"
PACKAGES_TARGET="$IOS_ROOT/Runner/app_packages"
case "$FRAMEWORK_TARGET" in "$IOS_ROOT"/*) ;; *) exit 1 ;; esac
case "$PACKAGES_TARGET" in "$IOS_ROOT"/*) ;; *) exit 1 ;; esac
rm -rf "$FRAMEWORK_TARGET" "$PACKAGES_TARGET"
tar -xzf "$ARCHIVE" -C "$IOS_ROOT" Python.xcframework

mkdir -p "$PACKAGES_TARGET"
python3 -m pip install \
  --disable-pip-version-check \
  --no-compile \
  --target "$PACKAGES_TARGET" \
  "yt-dlp==$YTDLP_VERSION"

find "$PACKAGES_TARGET" -type d -name '__pycache__' -prune -exec rm -rf {} +
echo "Prepared iOS local parser: Python 3.14 + yt-dlp $YTDLP_VERSION"
