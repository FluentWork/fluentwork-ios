# FluentWork iOS

`fluentwork-ios` is the SwiftUI client for FluentWork — the English speaking-practice app.

The repository is a Swift Package (`FluentWorkIOS`) plus a thin Xcode host app
(`FluentWorkHost`). The host app exists to produce a runnable `.app` and to own the
Info.plist surface (microphone, speech recognition, background audio). Product code
lives in the package.

## Requirements

- macOS with a Swift 6 toolchain (verified against Apple Swift 6.4)
- iOS 17.0+ / macOS 14.0+ deployment targets
- XcodeGen 2.46.0+ — `project.yml` is the source of the Xcode project

## Build and test

```bash
swift build                 # build the package
swift test                  # run the test suite (FluentWorkCoreTests)
```

Both work as-is on a normal macOS toolchain. If the toolchain sandbox refuses to
start the macro plugin server (`sandbox_apply: Operation not permitted`), pass
`--disable-sandbox`:

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```

Regenerate the Xcode project after editing `project.yml`:

```bash
xcodegen generate           # project.yml -> FluentWorkHost.xcodeproj
```

`FluentWorkHost.xcodeproj` is **tracked**, so a regenerate shows up as a diff.

## Package layout

Products: `FluentWorkCore`, `FluentWorkDiagnostics`, `FluentWorkUI`.

| Target | Path | Depends on |
|---|---|---|
| `FluentWorkFeatureFlags` | `Shared/FluentWorkFeatureFlags` | TGReduxKit, TGFeatureFlag |
| `FluentWorkPluginSupport` | `Shared/FluentWorkPluginSupport` | FluentWorkFeatureFlags |
| `FluentWorkDiagnostics` | `Shared/FluentWorkDiagnostics` | — |
| `FluentWorkNetworking` | `Shared/FluentWorkNetworking` | Moya |
| `FluentWorkObjCSupport` | `Shared/FluentWorkObjCSupport` | — (Objective-C) |
| `FluentWorkCore` | `Shared/FluentWorkCore` | TGReduxKit, FactoryKit, TGNavigationStack, FeatureFlags, PluginSupport, Networking, Diagnostics, ObjCSupport |
| `FluentWorkUI` | `Shared/FluentWorkUI` | FluentWorkCore |
| `FluentWorkCoreTests` | `Tests/FluentWorkCoreTests` | the six targets above + Moya, TGReduxKit, TGReduxKitTesting, TGNavigationStack, FactoryKit |

`FluentWorkObjCSupport` is Objective-C and exists for one thing: `FWTryCatch`.
Swift cannot catch `NSException`, and `AVAudioPlayerNode.play()` raises instead of
returning an error.

`FluentWorkCore` is organised by concern: `Architecture`, `Audio`, `Debug`,
`Dependencies`, `Navigation`, `Permissions`, `Prompt`, `Services`, `SpeechSession`,
`Storage`, `TTS`, plus `Resources`. `FluentWorkUI` holds the screens:
`SpeakingRoom`, `Review`, `DailyRead`, `SessionHistory`, `Corpus`, `Workbench`,
`Settings`, `BadgeFeedback`, `DesignTokens`.

## Host app

`App/FluentWorkHost/` contains two files:

- `FluentWorkHostApp.swift` — the `@main` entry point. Owns the `AppStore` and maps
  `ScenePhase` transitions into `.speakingRoom(.session(...))` dispatches.
- `HostRootView.swift` — the root view. Renders the tab shell and every route
  destination (`speakingRoom`, `review`, `dailyRead`, `sessionHistory`,
  `sessionDetail`), and translates store state into the UI layer's plain view models.

The host depends on the package products `FluentWorkCore` and `FluentWorkUI`.
Bundle id `com.fluentwork.host`, development team `UKXWZ3FS84` (declared in
`project.yml`, not only in the generated project — a setting device testing depends
on must not live only in a regenerated artifact).

## Dependencies

| Package | Pin | Source |
|---|---|---|
| TGReduxKit | `from: 5.0.1` | `tangzzz-fan/TGReduxKit` |
| Factory | `exact: 3.3.2` | `hmlongco/Factory` |
| Moya | `branch: "master"` | `tangzzz-fan/Moya` |
| TGNavigationStack | `from: 1.1.0` | `tangzzz-fan/TGNavigationStack` |
| TGFeatureFlag | `from: 0.5.0` | `tangzzz-fan/TGFeatureFlag` |

Moya is pinned to a **branch**, not a version — the only unpinned dependency in the
graph. `Package.resolved` records the revision it currently resolves to.

## Shared schemas

The WSS control-frame and speech-observability schemas are owned by
`fluentwork-infra`. This repo keeps mirrors for tests and packaging:

```bash
./Scripts/sync-shared-schemas.sh    # infra/schemas/** -> Shared/FluentWorkCore/Resources/Schemas/
```

Change the schema in `fluentwork-infra` first, then sync outward.

## Landing gate

The commit gate is described in `AGENTS.md`. In short: `swift test` green and the
`FluentWorkHost` Debug build succeeds, committed together. No document is part of the
gate — record the evidence in the commit body.
`.githooks/pre-commit` is intentionally a no-op (`exit 0`) — it does not run
`swift-format`, `swiftlint`, or gstack. Enable the hook path with
`./Scripts/setup-git-hooks.sh`; note that `core.hooksPath` is **not** set in a fresh
clone, so nothing runs automatically until you do.

Formatting and linting are manual or CI-time:

```bash
./Scripts/swift-format-staged.sh    # swift format on staged Swift files
./Scripts/swiftlint-staged.sh       # swiftlint --strict on staged Swift files
```

`.swift-format.json` is the source of truth for layout; `.swiftlint.yml` disables the
rules it disagrees with.

## Scripts

| Script | Purpose |
|---|---|
| `setup-git-hooks.sh` | point `core.hooksPath` at `.githooks` |
| `swift-format-staged.sh` / `swiftlint-staged.sh` | format / lint staged Swift files |
| `smoke-iphone17pro.sh` | boot an iPhone 17 Pro simulator, build + launch the host, run the launch/navigation tests |
| `instruments-baseline.sh` | Instruments baseline capture |
| `sync-shared-schemas.sh` | mirror infra schemas into `Resources/Schemas` |
| `gstack-review-gate.sh` | interactive-review attestation (not wired into pre-commit here) |
| `ocr-*.sh` | OpenCodeReview helpers — paused, optional/manual only |

## CI

- `ios-ci.yml` — `repo-structure-check` (asserts a directory skeleton) and
  `swift-package-test` (`swift build` + `swift test` on `macos-latest`).
- `agent-config-check.yml` — requires `CLAUDE.md` and `AGENTS.md` to exist and to
  contain the string `fluentwork-meta`.

**Known drift:** `repo-structure-check` asserts `App`, `Modules`, `Shared`,
`Services`, `Resources`, `Tests`. Only `App`, `Shared`, `Tests` and `Scripts` exist —
`Modules/`, `Services/` and `Resources/` are not in this repository, so that job fails
regardless of the change under review. Treat `swift-package-test` as the real signal
until the skeleton list is corrected.

## Related repositories

- `fluentwork-meta` — product, architecture and governance source of truth
- `fluentwork-backend` — Go services (`app-server`, `voice-gateway`, `worker`)
- `fluentwork-infra` — deployment, environments, shared schemas
