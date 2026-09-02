# FluentWork iOS — Pending Tasks

## AuthTokenStoreProtocol → async throws

**Status:** done (2026-09-02)
**Created:** 2026-09-02
**Implementation:** see `docs/17_AuthTokenStore_Async迁移方案.md`

### Result
- 216/216 tests pass.
- `SecureStorageProtocol` is now `async throws` (Keychain uses `Task.detached`,
  InMemory fake is `actor` isolated).
- All callers — `TokenRefreshCoordinator`, `DefaultSpeechSessionClient`,
  `DefaultDailyReadClient`, `DefaultCorpusClient`, `ResolverBackedBootstrapClient`
  — updated to `await`.
- Test mocks for all 7 token-store touchpoints updated.

### Open follow-ups (parked, separate PRs)
- [ ] Map `OSStatus` → typed `AuthStorageError` for higher-level recovery
- [ ] Make `SecureAuthTokenStore.deviceID()` race-safe across concurrent bootstraps
- [ ] Add "Layer 0" cache in `SecureAuthTokenStore` to dedupe keychain reads on startup
