#!/usr/bin/env bash
# Point this clone at the repo-managed hooks (local OCR pre-commit gate).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -d "$ROOT/.githooks" ]]; then
  echo "error: .githooks/ missing in $ROOT" >&2
  exit 1
fi

git config core.hooksPath .githooks
echo "Enabled core.hooksPath=.githooks for $(basename "$ROOT")"
<<<<<<< Updated upstream
echo "Pre-commit will run local OpenCodeReview (SKIP_OCR=1 to bypass)."

=======
echo "pre-commit requires gstack /review attestation:"
echo "  GSTACK_REVIEWED=1 git commit ..."
echo "Emergency bypass: SKIP_GSTACK_REVIEW=1 (justify in commit/PR body)"
>>>>>>> Stashed changes
