# AGENTS

## Repository

- Name: `fluentwork-ios`
- Role: SwiftUI app implementation for FluentWork

## Shared Rules

This repository inherits shared agent policy from `FluentWork/fluentwork-meta/agents/shared/`.

Shared topics:

1. AI collaboration and role split
2. Git and PR rules — **superseded locally**: work on `main`, fast-forward only, no PRs unless asked
3. Review gate — **superseded locally**: required gate is build + `swift test` plus an implementation note (see Local Review Gate). gstack is not part of the gate
4. Skills policy
5. Matt Pocock skills usage boundary

## Local Rules

1. Follow upstream iOS architecture and UI design docs.
2. Protect AudioEngine, SpeechSession, and release-critical paths.
3. Prefer explicit state boundaries over broad cross-module rewrites.
4. Keep implementation and tests aligned.
5. Do not use `NSLock`, `NSRecursiveLock`, or other explicit lock-based synchronization. Prefer actor isolation or a dedicated serial executor/queue that preserves the repository's supported OS versions.
6. Work on exactly one ticket at a time. Do not implement, test, or advance multiple planned tasks concurrently.
7. Cross-repository iOS/backend work must be sequential: finish and verify the active task in one repository before starting work in the other repository.
8. Develop on `main`. Pull and push with `--ff-only`. Do not open merge requests or pull requests unless the user explicitly asks.
9. Landing gate is a passing host Debug build plus `swift test`, then an implementation-note doc committed with the code. Do not treat gstack `/review` or `GSTACK_REVIEWED=1` as required.

## Required Behaviors

1. Read current iOS and product docs before editing.
2. Keep changes scoped to the active module.
3. Do not land on `main` without a passing build and test run.
4. Do not create PRs or MRs as part of the default workflow. Fast-forward `main` after build and test pass.
5. Do not perform destructive git operations without explicit approval.
6. Call out any impact on state, audio, or release behavior.
7. After each completed ticket whose code gate passes, write a numbered implementation note under `docs/` and commit it together with the code and tests.
8. A reported defect is not fixed until a test that reproduces it exists — see Defect Fix Discipline.

## Defect Fix Discipline

Source of truth: `fluentwork-meta/agents/shared/defect-fix-discipline.md`.

**Every fix for a reported problem starts with a failing test that reproduces it.**

1. Write the test first. It must fail on the current code.
2. Run it. Confirm it fails, and that the failure points at the real cause. A test that passes on the first run means the problem is not reproduced — go back, or admit the diagnosis was wrong.
3. Only then change the code, and only until the test passes.
4. Run the full gate (`swift test` plus the Debug build).
5. Keep the test. It is the guard for that defect; do not delete it once it goes green.

Reproduce with local doubles rather than the device: `InMemorySocketTransport`, `StubAudioEngine`, `StubSpeechSessionClient`, `FixedClock`. "It needs real hardware" is rarely true for the mechanism — it is usually true only for the final confirmation.

Three exceptions, each of which must be stated in the implementation note: new capability (no failing state exists — pin the expected behaviour instead), device-only (reproduce with a double, then confirm on device), genuinely not automatable (write the manual steps and the expected log lines). "Cannot test" is not an acceptable omission.

The implementation note's test section must quote the **actual pre-fix failure output**, not a paraphrase of it.

## High-Risk Paths

1. Audio engine and interruption logic
2. SpeechSession state machine
3. Root store / dependency injection wiring
4. Release and debug bridge configuration

## Testing Index

Before writing or changing tests in bootstrap, audio, middleware, or navigation paths, read these docs first:

1. `docs/19_测试分层与依赖隔离规范.md` — test boundary, hermetic rules, stub policy
2. `docs/17_Bootstrap设计原理说明.md` — bootstrap layering and provider boundary
3. `docs/12_mock_device_测试支持说明.md` — device / mock support and local doubles
4. `docs/10_I12_audio_engine_decoder_pitfalls.md` — audio engine pitfalls and decoder constraints
5. `docs/09_I10_smoke_test_runbook.md` — iPhone 17 Pro simulator smoke scope

## Local Review Gate

Required before landing on `main`:

1. `swift test`
2. A Debug build of `FluentWorkHost`
3. An implementation-note file under `docs/` (next unused `NN_` number), covering:
   - the principle / contract the change is holding
   - the chosen scheme and the files that own it
   - the root cause of the bug being fixed, if any
   - why the new path exists instead of folding into an existing one
   - impact on state, protocol, audio, or release behavior
4. Commit the code, tests, and that doc together.

gstack is **not** a landing or pre-commit gate. Do not block commits on `/review`, `GSTACK_REVIEWED=1`, or `SKIP_GSTACK_REVIEW=1`. Interactive gstack skills remain optional helpers.

One-time hooks: `./Scripts/setup-git-hooks.sh` (sets `core.hooksPath=.githooks`). OCR scripts are optional/manual only.

## CI Boundary

CI validates build, tests, and configuration. CI does not run code review or a full interactive skills runtime.
