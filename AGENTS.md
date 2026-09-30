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
8. **Concurrency isolation is a closed table.** Pick from `## Concurrency Isolation`
   below by what the state has to do, not by taste. A strategy that is not in the table is
   a defect, not a preference — and `ConcurrencyPolicyTests` enforces that.

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
7. Search with the editor's search tool, not shell `grep`. macOS ships **BSD grep**, whose BRE
   treats `\|` as a literal, so `grep -n "a\|b" file` returns **nothing** instead of failing
   and `grep -v "a\|b"` passes **everything** through. Both halves have cost this repo real
   time: a search that "found nothing" (so a symbol looked unused), and a test run that looked
   green while a `FAIL` sat inside the output that was being filtered out. If you must use the
   shell, use `grep -E` with `|`, and print the exit status — see the gate commands in
   `Scripts/`.

## Concurrency Isolation

Pick by **what the state has to do**, not by taste. Measured 2026-09-29 over `Shared` +
`App`: 15 `actor` declarations, 23 `@MainActor` sites, 14 `OSAllocatedUnfairLock`, and
`NSLock` only in a test.

| The state… | Use | Why that one | Existing examples |
|---|---|---|---|
| does IO across `await`, or is a long-lived subsystem with its own invariants | `actor` | suspension is the boundary; an async API is the point | `Storage/*`, `LiveAudioEngine`, `URLSessionSocketTransport`, `TokenRefreshCoordinator`, `AuthenticatedNetworkClient` |
| is view / store state | `@MainActor` | it is only ever read from the main actor anyway | `AppStore`, `HostRootView`, `AppRootTabView` |
| is one or two fields that must be read **and written from a sync context** | `OSAllocatedUnfairLock` in a `final class: @unchecked Sendable` | `actor`'s `get`/`set` are `async`; reaching one from a sync `Middleware` closure forces a `Task { }`, and that is where the shape starts to bend | `TurnCountBox`, `SessionPhaseBox`, `OnceFlag`, `SpeechCaptureGate`, `SpeechSessionTimingsRecorder` |
| has to hand a queue to a **system API** | `DispatchQueue` | `NWPathMonitor` and notification observers demand one | `NWPathMonitor`'s queue in `NetworkMonitor` |

The list is closed. Not for new code:

- **`NSLock` / `NSRecursiveLock` / `DispatchSemaphore`.** `OSAllocatedUnfairLock` (iOS 16+)
  is the replacement, is already what the sync boxes use, and scopes the critical section
  with `withLock`. Production code has zero.
- **`DispatchQueue(label:)` + `.sync` used as a lock.** Same job as the lock, weaker
  guarantee, and it is exactly what `SecureStorage` was moved off. Files that still do it
  predate the rule and are listed in the guard.
- **`private actor` as a state box.** Row 3. `ActiveSessionBox`, `HeartbeatTaskBox` and
  `SessionTransitionGate` in `DefaultSpeechSessionClient` predate the rule.

`Tests/.../Architecture/ConcurrencyPolicyTests.swift` makes "closed" literal, for the two
halves that are machine-checkable: `NSLock` / `NSRecursiveLock` / `DispatchSemaphore` are
**zero-tolerance** in production (no allow-list — the replacement already exists and is
already in use), and every production file that uses `DispatchQueue` must be registered
there with a stated purpose. Adding a file to that list is a deliberate act; that act is
the whole point. The `private actor` half is **not** machine-checked and is not pretended
to be — it is prose plus three named instances.

## Audio State Boundary

Where audio state lives is not a matter of taste. The store holds what can be equated, replayed
and read by a screen; real-time or process-level facts stay behind a port. The rule and its two
exceptions were both derived from device runs -- and the exceptions are written down because the
next person's instinct is to add a third.

**In the store** (a pure reducer decides, a middleware applies the effect):

- The room's phase and its two "ready" halves (`socketReady`, `captureLive`) --
  `SpeechSessionMachine.reduce`. Audio *events* are its input, not a side channel:
  `SpeechSessionEvent.swift:26` names `audioEventPump` as the producer of `.captureFirstBuffer`.
- Daily read's playback phase (`DailyReadState.audioPhase`, `DailyReadFeature.swift:51`), with its
  transitions in the reducer (`:204-224`) and one action per fact the player reports.
- Every engine-to-action hop goes through `audioEventPump` (`SpeechSessionMiddleware.swift:456`)
  or the transport router (`TransportEventRouter.swift`). **Services never import the store.**

**Outside the store, deliberately** -- turning these into actions is the failure mode:

- `SharedAudioSessionOwner`'s lock and lease roster (`AudioSessionOwnership.swift:490`): a
  process-level resource that needs real mutual exclusion, and `AVAudioSession` cannot say *who is
  borrowing* -- see R2 in `.workbuddy-ai/reviews/2026-09-29-f6-review.md`. That is why "who holds
  the session" had to become a roster the owner keeps, not state the store could hold.
- The engine's graph, capture tap, ring buffer, `AudioSink` / `RecordingSink`, and the VAD energy
  state machine (`LiveAudioEngineSupport.swift:179-214`): a 20 ms signal. One action per frame is
  one main-thread hop per frame.

**Registered exceptions -- the phase has two homes:**

- `SessionPhaseBox` (`SpeechSessionMiddleware.swift:271`) and `SpeechCaptureGate` (`:298`) mirror
  state the store already owns. They exist because the pump must know the phase **synchronously,
  before it dispatches** (`:265-270`), and a `@MainActor` read is not available from the audio
  loop. That is the entire justification; anything else wanting a second home for the phase needs
  an argument at least that strong.

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

1. **`AppEnvironment.local` hardcodes a machine-specific IP — and it is committed.**
   `AppEnvironment.swift:39-40` points at `192.168.2.185` (committed in `8b99b81`), while the
   doc comment directly above it says "Default: 127.0.0.1 (simulator)". In `DEBUG`,
   `AppEnvironment.current` returns `LOCAL_HOST` if set and otherwise falls back to `.local` —
   i.e. to that hardcoded address, not to localhost. Set `LOCAL_HOST` in the scheme, or the app
   will talk to whatever machine that address belonged to. Do not commit a personal IP here:
   the value has already moved three times (`192.168.2.156` → `.181` → `.185`), which is what a
   per-machine value living in a tracked file looks like. `TestProcess`-scoped access uses
   `TEST_LOCAL_HOST` with a `127.0.0.1` fallback (`AppEnvironment.swift:56-62`) — that is the
   shape the non-test path needs.
2. **`wssBaseURL` is a dead field.** The WSS address the client actually uses comes
   from the `POST /sessions` response (`wss_url`), not from `AppEnvironment`.
   `AppEnvironment` only governs the HTTP base URL, so a wrong host there produces
   working HTTP and an instantly-failing WebSocket.
3. **`project.yml` and `Package.swift` can disagree, and nothing checks.** CI does not run
   `xcodegen`, and the landing gate builds the **committed** `.xcodeproj` — so renaming a
   target directory, a product, or `App/FluentWorkHost` breaks the host app in a way no
   automated step reports until someone regenerates the project by hand. `F8-b`.

## CI Boundary

CI runs `swift build` + `swift test` on `macos-latest` and validates that `CLAUDE.md`
and `AGENTS.md` exist and reference `fluentwork-meta`. CI does not run the interactive
gstack review skill and does not load a skills runtime.
