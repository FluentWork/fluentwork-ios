# FluentWork iOS — Pending Tasks

## AuthTokenStoreProtocol → async throws

**Status:** pending
**Created:** 2026-09-02

### Motivation
> [!NOTE]
> Awaiting clarification: why does this need to be async? `SecureStorageProtocol`
> (Keychain) and `IDGeneratorProtocol` are currently synchronous. Changing the
> protocol signature requires updating all callers and test mocks.

### Scope

The change ripples through the entire token-read/write path:

**Protocol** (`AuthTokenStore.swift`):
- `AuthTokenStoreProtocol` — add `async` to all methods

**Implementations**:
- `SecureAuthTokenStore` — update all method signatures
- Test stubs: `InMemoryAuthTokenStore` (DailyReadClientTests),
  `MockTokenStore` (TokenRefreshCoordinatorTests, AuthenticatedNetworkClientTests)

**Callers** (all need `await`):
- `TokenRefreshCoordinator`
- `DefaultSpeechSessionClient`
- `DefaultDailyReadClient`
- `DefaultCorpusClient`
- `AppDependencies` factory closures

**Root causes to resolve first:**
- Is `KeychainSecureStorage.read/write/delete` actually blocking on a lock?
  If yes → wrap in `Task` to make it async, or use `OSAllocatedUnfairLock` pattern
- Does `LAContext` (biometric) need to be introduced? If so → bigger scope

### Checklist
- [ ] Clarify async motivation
- [ ] Audit `KeychainSecureStorage` for blocking locks
- [ ] Decide: wrap callers in `Task {}` or make storage async first
- [ ] Update `AuthTokenStoreProtocol` signatures
- [ ] Update `SecureAuthTokenStore` implementation
- [ ] Update all test mocks
- [ ] Update all callers (add `await`)
- [ ] Run full test suite (190 tests)
- [ ] Verify on simulator + physical device
