#!/usr/bin/env bash
# First-wave iPhone 17 Pro simulator smoke for FluentWork Host + launch path tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
BUNDLE_ID="${BUNDLE_ID:-com.fluentwork.host}"
SCHEME="${SCHEME:-FluentWorkHost}"
PROJECT="${PROJECT:-FluentWorkHost.xcodeproj}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.derivedData/smoke-iphone17pro}"
LOG_DIR="${LOG_DIR:-$ROOT/.tmp/smoke-iphone17pro}"
SKIP_HOST_BUILD="${SKIP_HOST_BUILD:-0}"

usage() {
  cat <<'EOF'
Run the first-wave iPhone 17 Pro simulator smoke.

Usage:
  ./Scripts/smoke-iphone17pro.sh

What it proves:
  1. iPhone 17 Pro simulator can boot
  2. FluentWorkHost builds and launches on that simulator
  3. First-wave launch -> bootstrap ready -> speaking room / review navigation
     package tests stay green (Store-level evidence of the first-wave shell)

Environment overrides:
  SIMULATOR_NAME   default: iPhone 17 Pro
  BUNDLE_ID        default: com.fluentwork.host
  SKIP_HOST_BUILD  set to 1 to skip xcodebuild (tests only)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$LOG_DIR"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd xcrun
require_cmd xcodebuild
require_cmd swift

echo "== wave1 iOS smoke: resolve simulator ($DEVICE_NAME)"
DEVICE_ID="$(
  xcrun simctl list devices available |
    awk -v name="$DEVICE_NAME" '
      $0 ~ name && $0 ~ /\(/ {
        if (match($0, /\(([A-F0-9-]{36})\)/)) {
          print substr($0, RSTART + 1, RLENGTH - 2)
          exit
        }
      }
    '
)"
if [[ -z "$DEVICE_ID" ]]; then
  echo "simulator not found: $DEVICE_NAME" >&2
  echo "Create it in Xcode or: xcrun simctl create \"$DEVICE_NAME\" \"iPhone 17 Pro\"" >&2
  exit 1
fi
echo "  udid=$DEVICE_ID"

echo "== boot simulator"
if ! xcrun simctl boot "$DEVICE_ID" 2>/dev/null; then
  # already booted is fine
  :
fi
xcrun simctl bootstatus "$DEVICE_ID" -b
echo "  booted"

HOST_LAUNCH_OK="skipped"
if [[ "$SKIP_HOST_BUILD" != "1" ]]; then
  if [[ ! -d "$ROOT/$PROJECT" ]]; then
    echo "missing $PROJECT; generate with: xcodegen generate" >&2
    exit 1
  fi

  echo "== build FluentWorkHost for $DEVICE_NAME"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    build | tee "$LOG_DIR/xcodebuild-build.log"

  APP_PATH="$(
    find "$DERIVED_DATA/Build/Products" -type d -name 'FluentWorkHost.app' 2>/dev/null | head -n 1
  )"
  if [[ -z "$APP_PATH" ]]; then
    echo "FluentWorkHost.app not found under $DERIVED_DATA" >&2
    exit 1
  fi
  echo "  app=$APP_PATH"

  echo "== install + launch Host on simulator"
  xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$DEVICE_ID" "$APP_PATH"
  # Do not use --console-pty: SwiftUI host stays running and would hang the smoke.
  LAUNCH_OUT="$(xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" 2>&1)"
  echo "$LAUNCH_OUT" | tee "$LOG_DIR/simctl-launch.log" >/dev/null
  # launch returns "com.fluentwork.host: <pid>" on success
  if echo "$LAUNCH_OUT" | grep -Eq "${BUNDLE_ID}: [0-9]+"; then
    HOST_LAUNCH_OK="yes"
    echo "  launched ok ($LAUNCH_OUT)"
  else
    echo "Host launch failed:" >&2
    echo "$LAUNCH_OUT" >&2
    exit 1
  fi
else
  echo "== skip Host build (SKIP_HOST_BUILD=1)"
fi

echo "== first-wave launch/bootstrap package tests"
swift test \
  --filter 'launchBootstrapsFlagsThenPresentsSpeakingRoom|launchThenSwitchTabKeepsIndependentStacks|appRouteBridgesPluginEntryRoutes' \
  2>&1 | tee "$LOG_DIR/swift-test-launch.log"

echo
echo "=== wave1 iPhone 17 Pro smoke PASS ==="
echo "device: $DEVICE_NAME ($DEVICE_ID)"
echo "host_launch: $HOST_LAUNCH_OK"
echo "bootstrap_navigation_tests: pass"
echo "logs: $LOG_DIR"
echo "checklist:"
echo "  [x] simulator booted"
if [[ "$HOST_LAUNCH_OK" == "yes" ]]; then
  echo "  [x] Host app launched on simulator"
else
  echo "  [ ] Host app launched on simulator (skipped)"
fi
echo "  [x] bootstrap ready + speaking room / review navigation tests green"
