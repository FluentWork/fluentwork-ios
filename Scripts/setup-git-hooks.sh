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
echo "pre-commit does not run gstack. Landing gate is AGENTS.md:"
echo "  1. swift test"
echo "  2. FluentWorkHost Debug build"
echo "  3. docs/NN implementation note committed with the ticket"
