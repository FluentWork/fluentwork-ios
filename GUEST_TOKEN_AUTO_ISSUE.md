# Automatic Guest Token Issuance

## Overview

Implemented automatic guest token issuance during app bootstrap. When the app launches, if no valid access token exists in the keychain, the bootstrap process automatically calls the backend `/auth/guest` endpoint to obtain a new guest token before proceeding with the rest of the bootstrap flow.

## Changes Made

### 1. Modified `ResolverBackedBootstrapClient`

**File**: `Shared/FluentWorkCore/Dependencies/AppDependencies.swift`

Added two new dependencies to `ResolverBackedBootstrapClient`:
- `sessionAPI: SessionAPIClientProtocol` - for calling the guest token endpoint
- `tokenStore: AuthTokenStoreProtocol` - for reading/writing tokens to keychain

Added `ensureGuestToken()` method that:
1. Checks if an access token already exists in keychain
2. If no token exists, generates/retrieves a device ID
3. Calls `sessionAPI.issueGuest(deviceID:)` to obtain a new token
4. Saves the token response to keychain

The `loadBootstrap()` method now calls `ensureGuestToken()` before loading feature flags, ensuring a valid token exists before the app becomes interactive.

### 2. Updated Container Factory

**File**: `Shared/FluentWorkCore/Dependencies/AppDependencies.swift`

Updated the `bootstrapClient` factory to inject the required dependencies:

```swift
var bootstrapClient: Factory<BootstrapClientProtocol> {
    self {
        ResolverBackedBootstrapClient(
            resolver: self.featureFlagResolver(),
            preferredSurfaceProvider: self.preferredSurfaceProvider(),
            sessionAPI: self.sessionAPIClient(),
            tokenStore: self.authTokenStore()
        )
    }.singleton
}
```

### 3. Updated Test Files

Updated direct construction sites in test files to pass the new required dependencies:

- **LaunchToNavigationEndToEndTests.swift**: Updated `makeIsolatedLaunchContainer()`
- **BootstrapSurfaceProviderTests.swift**: Updated `makeTestContainer()` and inline test container construction

## How It Works

### Bootstrap Flow (with Auto Guest Token)

```
1. User launches app
2. AppBootstrapMiddleware triggered by .lifecycle(.appLaunched)
3. bootstrapClient.loadBootstrap() called
   ├─ 3a. ensureGuestToken() checks keychain
   │   ├─ If token exists: return immediately
   │   └─ If no token:
   │       ├─ Get/generate device ID from keychain
   │       ├─ Call POST /auth/guest with device_id
   │       └─ Save token response to keychain
   ├─ 3b. Load feature flags from resolver
   └─ 3c. Return BootstrapSnapshot with flags + preferred surface
4. .lifecycle(.bootstrapSucceeded) dispatched
5. App UI becomes interactive with valid guest token
```

### Token Lifecycle

- **First Launch**: No token exists → auto-issue guest token → save to keychain
- **Subsequent Launches**: Token exists → skip guest token issuance → proceed with bootstrap
- **Token Expiry**: If the token expires later during runtime, existing refresh/re-auth logic handles it (not changed by this implementation)

## Benefits

1. **Zero Manual Setup**: No need to manually call guest login before using the app
2. **Transparent**: Happens automatically during bootstrap, user never sees "logging in"
3. **Idempotent**: Safe to run multiple times - won't re-issue if token already exists
4. **Testable**: Test containers can inject mock dependencies to test token issuance flow

## Testing

The implementation includes:
- ✅ Build verification passed
- ✅ Updated all test construction sites
- ✅ No breaking changes to existing APIs

Manual testing needed:
1. Delete app → Fresh install → Verify guest token issued automatically
2. Launch with existing token → Verify no redundant API call
3. Speaking room session → Verify token used successfully

## Migration Notes

**No migration needed** - this is a transparent enhancement that works automatically for all users (new and existing).

Existing users with tokens will skip the guest issuance step. New users will automatically get a guest token on first launch.

## Related Files

- `Shared/FluentWorkCore/Dependencies/AppDependencies.swift` - Bootstrap client implementation
- `Shared/FluentWorkCore/Services/AuthTokenStore.swift` - Token persistence
- `Shared/FluentWorkNetworking/SessionAPIClient.swift` - Guest token API endpoint
- `Shared/FluentWorkCore/Architecture/Middleware/AppBootstrapMiddleware.swift` - Bootstrap orchestration
