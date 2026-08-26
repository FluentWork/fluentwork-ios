# FluentWork iOS

`fluentwork-ios` is the SwiftUI application repository for FluentWork.

## Scope

This repository will contain:

- the iOS app project
- app routing and state containers
- SwiftUI pages and reusable components
- service adapters and local persistence
- unit tests, snapshot tests, and simulator checks
- release workflow for TestFlight delivery

## Planned Structure

```text
App/
Modules/
Shared/
Services/
Resources/
Tests/
Scripts/
.github/
```

## Engineering Baseline

- SwiftUI first
- iOS 17+
- explicit state management
- dependency injection
- simulator verification on iPhone 17 Pro
- real-device QA can be added later as a release gate
- shared agent policy comes from `fluentwork-meta`
- external helpers such as gstack and Matt Pocock style skills are allowed, but repo rules win on conflicts

## CI Goals

- build validation
- lint and format checks
- unit tests
- snapshot tests
- simulator smoke run
- agent entry file validation
<<<<<<< Updated upstream
- local OpenCodeReview pre-commit gate: `high`/`critical` findings fail the commit; `medium`/`low` do not
=======
- pre-commit gstack `/review` attestation (`GSTACK_REVIEWED=1`); CI does not run code review
>>>>>>> Stashed changes

## Upstream Source of Truth

Product and architecture decisions should come from `fluentwork-meta`.

## Current Initialization Status

This repository currently includes:

- `CLAUDE.md`
- `AGENTS.md`
- `CODEOWNERS`
- `Package.swift`
- `.github/workflows/agent-config-check.yml`
- `.github/workflows/ios-ci.yml`
<<<<<<< Updated upstream
- `.githooks/pre-commit` + `Scripts/setup-git-hooks.sh` (local OCR gate)
=======
- `.githooks/pre-commit` + `Scripts/setup-git-hooks.sh` + `Scripts/gstack-review-gate.sh`
>>>>>>> Stashed changes
- executable Swift package baseline
- initial directory skeleton

## Agent Tooling

<<<<<<< Updated upstream
- `gstack` can be used locally for deeper `/review`, `/qa`, and later release-oriented workflows
- OpenCodeReview CLI (`ocr`) is the **commit gate**: enable hooks once with `./Scripts/setup-git-hooks.sh`
- pre-commit runs `./Scripts/ocr-local-review.sh` (uses `.opencodereview/rule.json` + `ocr-fail-on-high.sh`)
- after a review, optionally run `./Scripts/ocr-export-review.sh` to save findings under `.opencodereview/reviews/` (see `latest.md`)
- Matt Pocock style skills may be used as helpers under FluentWork shared governance
- GitHub CI no longer runs OpenCodeReview; keep review local before commit
=======
- **gstack `/review`** before commit, then `GSTACK_REVIEWED=1 git commit ...`
- emergency bypass: `SKIP_GSTACK_REVIEW=1` (justify in commit/PR)
- `gstack` `/qa` and later release-oriented workflows remain available
- OCR scripts optional/manual only; not part of default pre-commit
- Matt Pocock style skills may be used as helpers under FluentWork shared governance
- GitHub CI does not run code review
>>>>>>> Stashed changes
