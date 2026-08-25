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
4. OpenCodeReview `high` / `critical` findings must be fixed before merge; absence of `high`/`critical` allows merge (`medium`/`low` may remain as follow-ups).
5. Do not perform destructive git operations without explicit approval.
6. Call out any impact on state, audio, or release behavior.

## High-Risk Paths

1. Audio engine and interruption logic
2. SpeechSession state machine
3. Root store / dependency injection wiring
4. Release and debug bridge configuration

## CI Boundary

CI validates build, tests, and configuration. CI does not run a full interactive skills runtime.
