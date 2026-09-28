#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export USER="${USER:-$(id -un)}"
mkdir -p "$ROOT/.tmp"

FAILED=""

echo "== leg 1/2  swift test"
swift test --disable-sandbox
if [[ $? -ne 0 ]]; then
  FAILED="leg 1 swift test"
  echo "leg 1 FAILED"
else
  echo "leg 1 OK"
fi

echo
echo "== leg 2/2  FluentWorkHost Debug build"
LOG="$ROOT/.tmp/gate-build.log"
xcodebuild \
  -scheme FluentWorkHost \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$ROOT/.derivedData" \
  -disableAutomaticPackageResolution \
  -IDEPackageSupportDisableManifestSandbox=1 \
  -IDEPackageSupportDisablePluginExecutionSandbox=1 \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  build >"$LOG" 2>&1

status=$?
if [[ $status -ne 0 ]]; then
  FAILED="${FAILED:+$FAILED; }leg 2 host build (exit $status)"
  echo "leg 2 FAILED (exit $status) — tail of $LOG"
  tail -25 "$LOG"
else
  errors="$(grep -cE 'error:' "$LOG" || true)"
  echo "leg 2 OK  (error: count $errors, log $LOG)"
fi

echo
if [[ -n "$FAILED" ]]; then
  echo "GATE FAILED: $FAILED"
  exit 1
fi
echo "GATE PASSED"
