# AGENTS

## Repository

- Name: `fluentwork-ios`
- Role: SwiftUI client for FluentWork — a Swift Package (`FluentWorkIOS`) plus a thin
  Xcode host app (`FluentWorkHost`)

## Shared Rules

This repository inherits shared agent policy from `fluentwork-meta/agents/shared/`.

Shared topics:

1. AI collaboration and role split
2. Git and PR rules
3. Review gate
4. Defect fix discipline (reproduce → fix → keep the guard → prove the guard bites)
5. Skills policy
6. Matt Pocock skills usage boundary

Read the shared file before inventing a local rule. This file only adds what is
specific to this repository.

## Local Rules

1. **Landing gate.** `swift test` green and the `FluentWorkHost` Debug build succeeds,
   committed together with the ticket. No document is part of the gate.
   `Scripts/setup-git-hooks.sh` and `.githooks/pre-commit` both state this.
2. **The gate does not run itself.** `.githooks/pre-commit` is `exit 0` (deliberately —
   it runs neither `swift-format`, `swiftlint`, nor gstack), and `core.hooksPath` is
   unset in a fresh clone. A successful `git commit` is therefore **not** evidence the
   gate passed. Run `swift test` yourself.
3. **`project.yml` is the source of the Xcode project.** `FluentWorkHost.xcodeproj` is
   tracked but generated — edit `project.yml` and re-run `xcodegen generate`. Any
   setting device testing depends on (bundle id, `DEVELOPMENT_TEAM`, Info.plist keys)
   must be declared in `project.yml`; a setting that lives only in the generated
   project is silently dropped on the next regenerate.
4. **Schemas are owned by `fluentwork-infra`.** Never hand-edit
   `Shared/FluentWorkCore/Resources/Schemas/*.json`. Change the schema in
   `fluentwork-infra/schemas/`, then run `./Scripts/sync-shared-schemas.sh`.
5. **No code comments.** Do not add header blocks, doc comments, or inline rationale to
   new or changed code unless explicitly asked. If the reasoning needs recording, it goes
   in the commit body. Leave existing comments alone.
6. **`.swift-format.json` is the layout source of truth.** `.swiftlint.yml` disables
   the rules that disagree with it (notably `trailing_comma` and `line_length`); do
   not "fix" formatting to satisfy a disabled rule.
7. **Draw the load-bearing flows; do not narrate them in comments.** A flow through a
   path listed under High-Risk Paths is explained with a diagram in the commit body, not
   with prose and not with a comment. A comment may state a rule someone would otherwise
   break; it may not carry the shape of a flow. When the flow changes, redraw it.

## Required Behaviors

1. Read the current code before editing. The package layout and target graph in
   `Package.swift` are authoritative; do not infer structure from directory names.
2. Keep changes scoped to the active task. One ticket per commit.
3. Do not bypass review, CI, or owner approval requirements.
4. Do not perform destructive git operations without explicit approval.
5. Surface risks clearly when touching high-risk areas.
6. When you fix a defect, leave a test that failed before the fix — see
   `fluentwork-meta/agents/shared/defect-fix-discipline.md`. A green suite after the
   fix is not evidence the guard works; break the implementation and confirm the
   *expected* test goes red.

## High-Risk Paths

1. `Shared/FluentWorkCore/Audio/` — capture and playback; `AVAudioPlayerNode.play()`
   raises rather than returning an error (this is why `FluentWorkObjCSupport` exists).
2. `Shared/FluentWorkCore/SpeechSession/` — the session/turn state machine. A wrong
   transition here is a silent hang or a dropped turn, not a crash.
3. `Shared/FluentWorkCore/TTS/` and the WSS transport — binary frame layout is shared
   with `fluentwork-backend` and the frozen schema in `fluentwork-infra`.
4. `Shared/FluentWorkCore/AppEnvironment.swift` — see drift note below.
5. `App/FluentWorkHost/HostRootView.swift` — route → state → view-model translation for
   every screen.
6. `project.yml` — regenerating the project can silently change signing and Info.plist.

## Known Drift

These are measured, not suspected. Fix or work around them deliberately.

1. **`AppEnvironment.local` hardcodes a machine-specific IP.** `AppEnvironment.swift:39-40`
   points at `192.168.2.156`, while the doc comment directly above it says
   "Default: 127.0.0.1 (simulator)". In `DEBUG`, `AppEnvironment.current` returns
   `LOCAL_HOST` if set and otherwise falls back to `.local` — i.e. to that hardcoded
   address, not to localhost. Set `LOCAL_HOST` in the scheme, or the app will talk to
   whatever machine that address belonged to. Do not commit a personal IP here.
2. **`wssBaseURL` is a dead field.** The WSS address the client actually uses comes
   from the `POST /sessions` response (`wss_url`), not from `AppEnvironment`.
   `AppEnvironment` only governs the HTTP base URL, so a wrong host there produces
   working HTTP and an instantly-failing WebSocket.
3. **CI `repo-structure-check` asserts directories that do not exist.** `ios-ci.yml`
   requires `Modules`, `Services`, `Resources`; the repository has `App`, `Shared`,
   `Tests`, `Scripts`. That job fails on every push regardless of the diff.

## CI Boundary

CI runs `swift build` + `swift test` on `macos-latest` and validates that `CLAUDE.md`
and `AGENTS.md` exist and reference `fluentwork-meta`. CI does not run the interactive
gstack review skill and does not load a skills runtime.
