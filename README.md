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
- pre-commit gstack review attestation (`GSTACK_REVIEWED=1`); CI does not run code review

## Local Pre-commit

After `./Scripts/setup-git-hooks.sh`, local `pre-commit` runs:

1. gstack review attestation gate via `Scripts/gstack-review-gate.sh`
2. `swift format` on staged `.swift` files
3. `swiftlint` on staged `.swift` files

Notes:

- local global gstack skill root: `/Users/apple/.codex/skills/gstack`
- project-local gstack skill mirror: `.trae/skills/gstack/SKILL.md` (mirrors the global router so the repo can expose a local skill entry)
- the hook cannot execute the interactive review skill itself; run it manually in your AI session with **`/review`** or **`/gstack-review`** when skill prefixes are enabled, then attest with `GSTACK_REVIEWED=1`
- emergency bypass remains `SKIP_GSTACK_REVIEW=1` and must be justified in commit/PR text

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
- `.githooks/pre-commit` + `Scripts/setup-git-hooks.sh` + `Scripts/gstack-review-gate.sh`
- `Scripts/swift-format-staged.sh` + `Scripts/swiftlint-staged.sh`
- executable Swift package baseline
- initial directory skeleton

## Agent Tooling

- before commit, run the interactive gstack review skill in your AI session: usually **`/review`**, or **`/gstack-review`** if skill prefixes are enabled; then `GSTACK_REVIEWED=1 git commit ...`
- emergency bypass: `SKIP_GSTACK_REVIEW=1` (justify in commit/PR)
- `gstack` `/qa` and later release-oriented workflows remain available
- OCR scripts optional/manual only; not part of default pre-commit
- Matt Pocock style skills may be used as helpers under FluentWork shared governance
- GitHub CI does not run code review
