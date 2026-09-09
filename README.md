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

## First-wave simulator smoke

```bash
./Scripts/smoke-iphone17pro.sh
```

Boots `iPhone 17 Pro`, builds/launches `FluentWorkHost`, and runs launch → bootstrap → speaking-room/review navigation tests. See `docs/06_第一波iPhone17Pro_Smoke_Runbook.md`.

Shared schema mirrors are stored under `Shared/FluentWorkCore/Resources/Schemas/`
and synced from `fluentwork-infra` with `./Scripts/sync-shared-schemas.sh`.

## CI Goals

- build validation
- lint and format checks
- unit tests
- snapshot tests
- simulator smoke run
- agent entry file validation
- landing on `main` is fast-forward only after a passing build, `swift test`, and an implementation-note doc under `docs/`; do not open PRs unless asked
- gstack is not part of the landing or pre-commit gate; CI does not run code review

## Local Pre-commit

After `./Scripts/setup-git-hooks.sh`, `core.hooksPath` points at `.githooks`. The hook does not run gstack, `swift format`, or `swiftlint`. The landing gate is in `AGENTS.md`.

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
- `.githooks/pre-commit` + `Scripts/setup-git-hooks.sh`
- `Scripts/swift-format-staged.sh` + `Scripts/swiftlint-staged.sh`
- executable Swift package baseline
- initial directory skeleton

## Agent Tooling

- landing a ticket: pass `swift test` + FluentWorkHost Debug build, add a numbered `docs/` implementation note, commit them together (see `AGENTS.md`)
- gstack skills remain optional helpers; they are not a commit gate
- OCR scripts optional/manual only
- Matt Pocock style skills may be used as helpers under FluentWork shared governance
- GitHub CI does not run code review
