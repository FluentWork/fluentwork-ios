#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGED_SWIFT_FILES_RAW="$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.swift$' || true)"

if [[ -z "$STAGED_SWIFT_FILES_RAW" ]]; then
  echo "swift format: no staged Swift files; skipping."
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift CLI not found; cannot run swift format." >&2
  exit 1
fi

echo "$STAGED_SWIFT_FILES_RAW" | while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  echo "swift format: formatting $file"
  swift format format --in-place "$file"
  git add -- "$file"
done
