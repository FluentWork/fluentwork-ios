#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGED_SWIFT_FILES_RAW="$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.swift$' || true)"

if [[ -z "$STAGED_SWIFT_FILES_RAW" ]]; then
  echo "swiftlint: no staged Swift files; skipping."
  exit 0
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: swiftlint not found; install SwiftLint before committing." >&2
  exit 1
fi

count=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  export "SCRIPT_INPUT_FILE_${count}=${file}"
  count=$((count + 1))
done <<EOF
$STAGED_SWIFT_FILES_RAW
EOF
echo "swiftlint: linting ${count} staged Swift file(s)"
export SCRIPT_INPUT_FILE_COUNT="$count"

swiftlint lint --strict --use-script-input-files --force-exclude
