# Bootstrap Surface Override

## Summary

The bootstrap flow now supports runtime configuration of the initial workspace surface via dependency injection.

## Changes

### `ResolverBackedBootstrapClient`

**Before:**
- Took a static `preferredSurface: WorkspaceSurface` parameter
- Value was fixed at initialization time

**After:**
- Takes a `preferredSurfaceProvider: @Sendable () -> WorkspaceSurface` closure
- Provider is called at bootstrap time, allowing dynamic evaluation

### Dependency Container

Added a new factory for the surface provider:

```swift
var preferredSurfaceProvider: Factory<@Sendable () -> WorkspaceSurface> {
    self {
        // Production default: speakingRoom
        // Debug builds can override via registration
        { .speakingRoom }
    }.singleton
}
```

## Usage

### Production (Default)

No changes required. The default remains `.speakingRoom`:

```swift
let container = Container.shared
let client = container.bootstrapClient()
// Will bootstrap with .speakingRoom
```

### Debug Override (Option 1: Direct Registration)

Override the surface provider factory:

```swift
#if DEBUG
Container.shared.preferredSurfaceProvider.register {
    { .dailyRead }  // Or any other WorkspaceSurface
}
#endif
```

### Debug Override (Option 2: Environment-Driven)

For runtime configuration based on launch arguments or environment:

```swift
#if DEBUG
Container.shared.preferredSurfaceProvider.register {
    {
        if ProcessInfo.processInfo.arguments.contains("--daily-read-first") {
            return .dailyRead
        }
        if ProcessInfo.processInfo.arguments.contains("--corpus-first") {
            return .corpus
        }
        return .speakingRoom
    }
}
#endif
```

### Test Override

Tests can inject a custom provider:

```swift
func testBootstrapWithDailyRead() async throws {
    let testContainer = Container()
    testContainer.preferredSurfaceProvider.register {
        { .dailyRead }
    }
    
    let client = testContainer.bootstrapClient()
    let snapshot = try await client.loadBootstrap()
    
    XCTAssertEqual(snapshot.preferredSurface, .dailyRead)
}
```

## Architecture Notes

1. **Closure vs Value**: Using a provider closure allows the decision to be deferred until bootstrap time, supporting dynamic selection based on runtime state.

2. **Sendable Conformance**: The provider is marked `@Sendable` to satisfy Swift concurrency requirements, since it's called from async contexts.

3. **Factory Pattern**: The provider itself is wrapped in a Factory, maintaining consistency with the rest of the dependency graph and enabling test isolation.

4. **Single Responsibility**: The bootstrap client remains focused on loading the snapshot; surface selection logic lives in the provider, which can be swapped independently.

## Migration

Existing code is **source-compatible**. The default behavior is unchanged.

Call sites that construct `ResolverBackedBootstrapClient` directly must update from:

```swift
// Before
ResolverBackedBootstrapClient(
    resolver: resolver,
    preferredSurface: .dailyRead
)

// After
ResolverBackedBootstrapClient(
    resolver: resolver,
    preferredSurfaceProvider: { .dailyRead }
)
```

## Future Extensions

This pattern enables:

1. **A/B Testing**: Provider can read from remote config
2. **Onboarding**: First-launch users see a different surface
3. **Context-Aware**: Provider can inspect user state, time of day, etc.
4. **Debug Menu**: Runtime surface picker in debug builds

## Related Files

- `Shared/FluentWorkCore/Dependencies/AppDependencies.swift` - Provider factory and bootstrap client
- `Shared/FluentWorkCore/Architecture/AppState.swift` - `BootstrapSnapshot` structure
- `Shared/FluentWorkCore/Architecture/AppReducer.swift` - Surface application in reducer
- `Shared/FluentWorkCore/Architecture/Middleware/AppBootstrapMiddleware.swift` - Bootstrap flow
