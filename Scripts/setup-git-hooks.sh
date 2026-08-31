#!/usr/bin/env bash
# Point this clone at the repo-managed hooks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GSTACK_SKILL_ROOT="${GSTACK_SKILL_ROOT:-$HOME/.codex/skills/gstack}"
GSTACK_BIN="$GSTACK_SKILL_ROOT/bin"
GSTACK_REVIEW_COMMAND="/review"
if [[ -x "$GSTACK_BIN/gstack-config" ]] && [[ "$("$GSTACK_BIN/gstack-config" get skill_prefix 2>/dev/null || echo false)" == "true" ]]; then
  GSTACK_REVIEW_COMMAND="/gstack-review"
fi

if [[ ! -d "$ROOT/.githooks" ]]; then
  echo "error: .githooks/ missing in $ROOT" >&2
  exit 1
fi

git config core.hooksPath .githooks
echo "Enabled core.hooksPath=.githooks for $(basename "$ROOT")"
echo "pre-commit now runs three gates in order:"
echo "  1. gstack review attestation"
echo "  2. swift format on staged Swift files"
echo "  3. swiftlint on staged Swift files"
echo
echo "gstack skill root (if installed globally): /Users/apple/.codex/skills/gstack"
echo "Run the gstack review skill manually in your AI session before commit:"
echo "  ${GSTACK_REVIEW_COMMAND}"
echo "Then attest for git commit:"
echo "  GSTACK_REVIEWED=1 git commit ..."
echo "Emergency bypass: SKIP_GSTACK_REVIEW=1 (justify in commit/PR body)"
