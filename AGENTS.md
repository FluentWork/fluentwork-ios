# AGENTS

## Repository

- Name: `fluentwork-ios`
- Role: SwiftUI app implementation for FluentWork

## Shared Rules

This repository inherits shared agent policy from `FluentWork/fluentwork-meta/agents/shared/`.

Shared topics:

1. AI collaboration and role split
2. Git and PR rules
3. Review gate
4. Skills policy
5. Matt Pocock skills usage boundary

## Local Rules

1. Follow upstream iOS architecture and UI design docs.
2. Protect AudioEngine, SpeechSession, and release-critical paths.
3. Prefer explicit state boundaries over broad cross-module rewrites.
4. Keep implementation and tests aligned.

## Required Behaviors

1. Read current iOS and product docs before editing.
2. Keep changes scoped to the active module.
3. Do not bypass review, CI, or owner approval requirements.
4. Before opening or merging a PR, run the interactive gstack review skill on the branch diff, normally **`/review`** and **`/gstack-review`** when skill prefixes are enabled; fix must-fix findings (see `fluentwork-meta/agents/shared/review-gate.md`).
5. Do not perform destructive git operations without explicit approval.
6. Call out any impact on state, audio, or release behavior.

## High-Risk Paths

1. Audio engine and interruption logic
2. SpeechSession state machine
3. Root store / dependency injection wiring
4. Release and debug bridge configuration

## Local Review Gate

1. Required before commit: run the interactive gstack review skill, normally **`/review`** in Codex/Cursor/Claude. If your gstack config enables skill prefixes, use **`/gstack-review`** instead. Then commit with `GSTACK_REVIEWED=1 git commit ...`.
2. pre-commit → `Scripts/gstack-review-gate.sh` (attestation; skill cannot run in bash).
3. One-time hooks: `./Scripts/setup-git-hooks.sh` (sets `core.hooksPath=.githooks`).
4. Emergency bypass: `SKIP_GSTACK_REVIEW=1` (justify in commit/PR body).
5. OCR scripts are optional/manual only; not part of the default gate.

## CI Boundary

CI validates build, tests, and configuration. CI does not run code review or a full interactive skills runtime.
