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
4. Before each commit, local OpenCodeReview must pass: fix any `high` / `critical` findings (see `Scripts/ocr-local-review.sh`); `medium` / `low` may remain as follow-ups.
5. Do not perform destructive git operations without explicit approval.
6. Call out any impact on state, audio, or release behavior.

## High-Risk Paths

1. Audio engine and interruption logic
2. SpeechSession state machine
3. Root store / dependency injection wiring
4. Release and debug bridge configuration

## Local Review Gate

1. One-time per clone: `./Scripts/setup-git-hooks.sh` (sets `core.hooksPath=.githooks`).
2. Pre-commit runs `Scripts/ocr-local-review.sh` (OCR CLI + `ocr-fail-on-high.sh`).
3. Emergency bypass only: `SKIP_OCR=1`, and justify in the commit/PR body.
4. Optional archive: `./Scripts/ocr-export-review.sh` after a review.

## CI Boundary

CI validates build, tests, and configuration. CI does not run OpenCodeReview or a full interactive skills runtime.
