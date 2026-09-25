# FluentWork iOS

## Repo Role

`fluentwork-ios` is the SwiftUI client for FluentWork. It ships a Swift Package
(`FluentWorkIOS` — products `FluentWorkCore`, `FluentWorkDiagnostics`, `FluentWorkUI`)
and a thin Xcode host app (`FluentWorkHost`) that produces the runnable `.app` and owns
the Info.plist surface.

## Shared Source Of Truth

Shared agent policy is maintained in `fluentwork-meta` under:

- `agents/shared/ai-collaboration.md`
- `agents/shared/git-and-pr-rules.md`
- `agents/shared/review-gate.md`
- `agents/shared/defect-fix-discipline.md`
- `agents/shared/skills-policy.md`
- `agents/shared/matt-pocock-skills.md`

Treat those files as the governance source. This file only adds iOS-specific
constraints. `AGENTS.md` in this repository is the fuller local entry point — read it
before changing code.

## Repo-Specific Constraints

1. **Build and test:** `swift build` / `swift test`. Add `--disable-sandbox` only if the
   toolchain sandbox blocks the macro plugin server.
2. **Landing gate:** `swift test` green + `FluentWorkHost` Debug build, committed
   together. No document is part of the gate. The pre-commit hook is a no-op and
   `core.hooksPath` is unset — the gate is manual.
3. **`project.yml` owns the Xcode project.** Regenerate with `xcodegen generate`; never
   hand-edit `FluentWorkHost.xcodeproj`. Signing and Info.plist keys belong in
   `project.yml`.
4. **Schemas:** change them in `fluentwork-infra`, then run
   `./Scripts/sync-shared-schemas.sh`. The copies under
   `Shared/FluentWorkCore/Resources/Schemas/` are mirrors.
5. **No code comments.** Reasoning goes in the commit body, not next to the code.
6. **`.swift-format.json` is the layout source of truth**; `.swiftlint.yml` disables
   rules that conflict with it.

## High-Risk Areas

1. `Shared/FluentWorkCore/Audio/` and `SpeechSession/` — real-time capture/playback and
   the turn state machine.
2. `Shared/FluentWorkCore/TTS/` and the WSS transport — binary frame layout shared with
   `fluentwork-backend`.
3. `Shared/FluentWorkCore/AppEnvironment.swift` — hardcodes a machine-specific local IP.
4. `App/FluentWorkHost/HostRootView.swift` — every route's state → view-model mapping.
5. `project.yml` — a regenerate can silently change signing.

## Expected Workflow

1. Read the code first; `Package.swift` is authoritative for the target graph.
2. Prefer minimal diffs over broad rewrites.
3. Update tests when behavior changes; a defect fix must leave a test that failed first.
4. Record what changed and why in the commit body. Do not create documents.
5. Respect review gates and owner approval for high-risk paths.
6. One ticket per commit; do not push without asking.

## Tooling Integrations

1. `gstack` review is not part of this repository's commit gate
   (`Scripts/gstack-review-gate.sh` exists but is not wired into `.githooks/pre-commit`).
2. `Scripts/ocr-*.sh` (OpenCodeReview) are paused and optional/manual only.
3. Matt Pocock style skills may be used as helpers, but FluentWork governance wins on
   conflicts.
