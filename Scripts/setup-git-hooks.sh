#!/usr/bin/env bash
# Point this clone at the repo-managed hooks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -d "$ROOT/.githooks" ]]; then
  echo "error: .githooks/ missing in $ROOT" >&2
  exit 1
fi

git config core.hooksPath .githooks
echo "Enabled core.hooksPath=.githooks for $(basename "$ROOT")"
echo "pre-commit now runs three gates in order:"
echo "  1. gstack /review attestation"
echo "  2. swift format on staged Swift files"
echo "  3. swiftlint on staged Swift files"
echo
echo "gstack skill root (if installed globally): /Users/apple/.codex/skills/gstack"
echo "pre-commit requires gstack /review attestation:"
echo "  GSTACK_REVIEWED=1 git commit ..."
echo "Emergency bypass: SKIP_GSTACK_REVIEW=1 (justify in commit/PR body)"
