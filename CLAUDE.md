# FluentWork iOS

## Repo Role

`fluentwork-ios` is the SwiftUI application repository for FluentWork.

It should implement the product and technical decisions defined upstream in `fluentwork-meta`, not redefine them locally.

## Shared Source Of Truth

Shared agent policy is maintained in `FluentWork/fluentwork-meta` under:

- `agents/shared/ai-collaboration.md`
- `agents/shared/git-and-pr-rules.md`
- `agents/shared/review-gate.md`
- `agents/shared/skills-policy.md`
- `agents/shared/matt-pocock-skills.md`

This file only adds iOS-specific constraints.

## Repo-Specific Constraints

1. Align all implementation with the iOS technical design and UI documents from `fluentwork-meta`.
2. Do not casually refactor AudioEngine, SpeechSession, or app-wide state boundaries.
3. Prefer minimal diffs and contract-preserving changes.
4. When behavior changes, update tests and any impacted iOS-facing docs.
5. Matt Pocock style skills may assist, but FluentWork iOS rules win on conflicts.

## High-Risk Areas

1. audio engine code
2. `SpeechSession` state machine
3. root app state and dependency injection wiring
4. test bridge / debug bridge / release-related configuration

## Expected Workflow

1. Read upstream docs and issue context first.
2. Keep UI, state, service, and audio changes scoped.
3. Add or update tests when behavior changes.
4. Respect CODEOWNERS and review gates for high-risk areas.
5. Treat real-device QA as an explicit gate, not an afterthought.

## Tooling Integrations

<<<<<<< Updated upstream
1. `gstack` may be used locally for review and QA assistance.
2. Matt Pocock style skills may be used as helpers under FluentWork shared policy.
3. Local OpenCodeReview runs on pre-commit (`Scripts/ocr-local-review.sh`): any `high`/`critical` finding blocks the commit until fixed; no `high`/`critical` means the commit may proceed (see `fluentwork-meta/agents/shared/review-gate.md`).
=======
1. **gstack `/review`** is required before commit; pre-commit expects `GSTACK_REVIEWED=1` (see `fluentwork-meta/agents/shared/review-gate.md`).
2. Matt Pocock style skills may be used as helpers under FluentWork shared policy.
3. CI does not run code review. OCR scripts are optional/manual only.
>>>>>>> Stashed changes
