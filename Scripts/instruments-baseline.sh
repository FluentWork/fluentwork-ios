#!/usr/bin/env bash
# Record Instruments Allocations / Leaks / Time Profiler against FluentWorkHost.
# Does not invent metrics. A 30-minute attach is a human-operated run; use --dry-run
# to print the resolved destination, scheme, and xctrace commands without recording.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

DRY_RUN=0
TIME_LIMIT="${TIME_LIMIT:-30m}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/build/instruments}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_ROOT/build/instruments-derivedData}"
PROJECT="${PROJECT:-FluentWorkHost.xcodeproj}"
PREFERRED_SCHEME="${PREFERRED_SCHEME:-FluentWorkHost}"
SKIP_BUILD="${SKIP_BUILD:-0}"
ATTACH_PID="${ATTACH_PID:-}"

usage() {
  cat <<'EOF'
Record Instruments Allocations, Leaks, and Time Profiler against FluentWorkHost.

This records Allocations/Leaks/Time Profiler against FluentWorkHost on an
iPhone 17 Pro simulator if available, else iPhone 16.

Usage:
  bash Scripts/instruments-baseline.sh
  bash Scripts/instruments-baseline.sh --dry-run

Environment:
  TIME_LIMIT          default: 30m (per template)
  OUT_DIR             default: <repo>/build/instruments
  DERIVED_DATA        default: <repo>/build/instruments-derivedData
  PREFERRED_SCHEME    default: FluentWorkHost
  SKIP_BUILD          set to 1 to reuse an existing .app
  ATTACH_PID          attach to a running pid instead of --launch
  SIMULATOR_NAME      override device name (exact simctl name)

Traces land under build/instruments/. This script does not analyze traces
or fill gate numbers; see docs/23_iOS-arch-baseline-report_2026-09-09.md.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

echo "== Instruments baseline"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "This records Allocations/Leaks/Time Profiler against FluentWorkHost on iPhone 17 Pro simulator if available, else iPhone 16."

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd xcrun
require_cmd xcodebuild

ensure_xcodeproj() {
  if [[ -d "$PROJECT_ROOT/$PROJECT" ]]; then
    return 0
  fi
  if [[ ! -f "$PROJECT_ROOT/project.yml" ]]; then
    echo "missing $PROJECT and project.yml; cannot resolve the host app scheme." >&2
    exit 1
  fi
  echo "missing $PROJECT; would run: xcodegen generate"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "install xcodegen, then: xcodegen generate" >&2
    exit 1
  fi
  xcodegen generate
}

scheme_from_project_yml() {
  local yml="$PROJECT_ROOT/project.yml"
  if [[ ! -f "$yml" ]]; then
    return 1
  fi
  if grep -Eq "^[[:space:]]*${PREFERRED_SCHEME}:" "$yml"; then
    echo "$PREFERRED_SCHEME"
    return 0
  fi
  awk '
    /^schemes:[[:space:]]*$/ { in_schemes=1; next }
    in_schemes && /^[^[:space:]#]/ { in_schemes=0 }
    in_schemes && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      name=$1
      sub(/:$/, "", name)
      print name
      exit
    }
  ' "$yml"
}

list_xcodebuild_schemes() {
  if [[ ! -d "$PROJECT_ROOT/$PROJECT" ]]; then
    return 1
  fi
  xcodebuild -list -project "$PROJECT_ROOT/$PROJECT" 2>/dev/null | awk '
    /Schemes:[[:space:]]*$/ { in_schemes=1; next }
    in_schemes && /^[[:space:]]*$/ { exit }
    in_schemes {
      gsub(/^[[:space:]]+/, "")
      if (length($0) > 0) print
    }
  '
}

resolve_scheme() {
  local yml_scheme=""
  local listed=""
  local candidate=""

  yml_scheme="$(scheme_from_project_yml || true)"
  listed="$(list_xcodebuild_schemes || true)"

  if [[ -n "$listed" ]]; then
    echo "xcodebuild -list schemes:" >&2
    echo "$listed" | sed 's/^/  /' >&2
  elif [[ "$DRY_RUN" != "1" ]]; then
    echo "xcodebuild -list returned no schemes for $PROJECT" >&2
    exit 1
  fi

  if [[ -n "$listed" ]] && echo "$listed" | grep -Fxq "$PREFERRED_SCHEME"; then
    echo "$PREFERRED_SCHEME"
    return 0
  fi
  if [[ -n "$yml_scheme" && -z "$listed" ]]; then
    echo "$yml_scheme"
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if [[ "$candidate" == *Host* ]]; then
      echo "$candidate"
      return 0
    fi
  done <<< "$listed"

  if [[ -n "$listed" ]]; then
    echo "$listed" | head -n 1
    return 0
  fi

  echo "could not pick a host app scheme from $PROJECT / project.yml" >&2
  exit 1
}

simulator_udid() {
  local name="$1"
  xcrun simctl list devices available | awk -v name="$name" '
    index($0, name " (") == 0 { next }
    {
      if (match($0, /\(([A-F0-9-]{36})\)/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  '
}

resolve_simulator() {
  local override="${SIMULATOR_NAME:-}"
  local name=""
  local udid=""

  if [[ -n "$override" ]]; then
    udid="$(simulator_udid "$override" || true)"
    if [[ -z "$udid" ]]; then
      echo "simulator not found: $override" >&2
      exit 1
    fi
    echo "$override|$udid"
    return 0
  fi

  for name in "iPhone 17 Pro" "iPhone 16"; do
    udid="$(simulator_udid "$name" || true)"
    if [[ -n "$udid" ]]; then
      echo "$name|$udid"
      return 0
    fi
  done

  echo "neither iPhone 17 Pro nor iPhone 16 simulator is available." >&2
  echo "Create one in Xcode or override SIMULATOR_NAME." >&2
  xcrun simctl list devices available | sed 's/^/  /' >&2 || true
  exit 1
}

print_scenario() {
  cat <<'EOF'
Scenario checklist (exercise during each recording):
  [ ] Enter speaking room
  [ ] Complete 5 turns (record ~5s, wait ~3s)
  [ ] Trigger an interruption (phone-call / AVAudioSession interrupt)
  [ ] Background ~5s, then foreground
  [ ] forceClose path, then leave speaking room
EOF
}

record_template() {
  local template="$1"
  local slug="$2"
  local output="$OUT_DIR/${slug}.trace"
  local -a cmd

  cmd=(
    xcrun xctrace record
    --template "$template"
    --device "$DEVICE_UDID"
    --output "$output"
    --time-limit "$TIME_LIMIT"
  )
  if [[ -n "$ATTACH_PID" ]]; then
    cmd+=(--attach "$ATTACH_PID")
  else
    cmd+=(--launch -- "$APP_PATH")
  fi

  echo "== xctrace record --template $template"
  printf '  %q' "${cmd[@]}"
  echo

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  (dry-run: not recording)"
    return 0
  fi
  if [[ -e "$output" ]]; then
    rm -rf "$output"
  fi
  "${cmd[@]}"
}

ensure_xcodeproj
SCHEME="$(resolve_scheme)"
echo "scheme=$SCHEME"

SIM_PAIR="$(resolve_simulator)"
DEVICE_NAME="${SIM_PAIR%%|*}"
DEVICE_UDID="${SIM_PAIR##*|}"
echo "simulator=$DEVICE_NAME udid=$DEVICE_UDID"

if [[ "$DRY_RUN" != "1" ]]; then
  mkdir -p "$OUT_DIR"
fi
echo "output=$OUT_DIR"
print_scenario

APP_PATH="${APP_PATH:-}"
if [[ "$DRY_RUN" == "1" ]]; then
  if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/${SCHEME}.app"
  fi
  echo "app=$APP_PATH (not built in dry-run)"
  echo "skipping xcodebuild build and xctrace record (--dry-run)"
else
  if [[ "$SKIP_BUILD" != "1" ]]; then
    if [[ ! -d "$PROJECT_ROOT/$PROJECT" ]]; then
      echo "missing $PROJECT after xcodegen; cannot build." >&2
      exit 1
    fi
    echo "== xcodebuild -scheme $SCHEME"
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
      -derivedDataPath "$DERIVED_DATA" \
      build
  else
    echo "== skip build (SKIP_BUILD=1)"
  fi

  if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$(
      find "$DERIVED_DATA/Build/Products" -type d -name "${SCHEME}.app" 2>/dev/null | head -n 1
    )"
  fi
  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "${SCHEME}.app not found under $DERIVED_DATA" >&2
    exit 1
  fi
  echo "app=$APP_PATH"

  echo "== boot simulator"
  if ! xcrun simctl boot "$DEVICE_UDID" 2>/dev/null; then
    :
  fi
  xcrun simctl bootstatus "$DEVICE_UDID" -b
fi

record_template "Allocations" "allocations"
record_template "Leaks" "leaks"
record_template "Time Profiler" "time-profiler"

echo
echo "=== Instruments baseline commands resolved ==="
echo "scheme: $SCHEME"
echo "device: $DEVICE_NAME ($DEVICE_UDID)"
echo "traces: $OUT_DIR/{allocations,leaks,time-profiler}.trace"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "status: dry-run only; no 30-minute Instruments attach was performed."
else
  echo "status: recording finished. Fill docs/23_iOS-arch-baseline-report_2026-09-09.md from the traces."
  echo "Do not invent gate numbers. Compare vs bf0ae8b only after a matching pre-change run."
fi
