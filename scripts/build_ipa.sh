#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_BASE_URL="${API_BASE_URL:-https://media-api.example.com}"
APP_VERSION="${APP_VERSION:-1.1.4}"

"$(cd "$(dirname "$0")" && pwd)/prepare_ios_local_parser.sh"
UPDATE_MANIFEST_URL="${UPDATE_MANIFEST_URL:-}"

cd "$PROJECT_ROOT/client"
flutter pub get
flutter build ipa --release \
  --build-name="$APP_VERSION" \
  --dart-define="APP_VERSION=$APP_VERSION" \
  --dart-define="API_BASE_URL=$API_BASE_URL" \
  --dart-define="UPDATE_MANIFEST_URL=$UPDATE_MANIFEST_URL" \
  "$@"
