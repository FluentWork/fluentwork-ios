# AuthTokenStoreProtocol → async throws 改造方案

> 同步问题：全链路 Token 读取/写入路径从 `throws` 切换到 `async throws`，
> 落地 iOS 启动链路与 SpeakingRoom 的"首响延迟"治理。

## 1. 动机（为什么不能用同步 throws）

`AuthTokenStoreProtocol` 在改造前的 `throws` 签名有两个隐性约束，都直接
影响 speaking room 的首响 P90：

1. **`SecureStorageProtocol` 实际是阻塞的。** `KeychainSecureStorage` 直接调用
   `SecItemCopyMatching` / `SecItemAdd` / `SecItemDelete`，这些 C API 虽然
   内部线程安全，但会同步触发与 `securityd` 的 IPC，单次延迟在 5-20ms 范围，
   偶发可达 100ms+（第一次热启动后 keychain 被换出场景）。
2. **调用点往往是热路径。** `TokenRefreshCoordinator`（actor）和
   `DefaultSpeechSessionClient.ensureAccessToken` 都是 speaking room
   开始 → token 刷新 → `/sessions` → WSS → `ai_speaking` 的关键路径。
   在 SwiftUI 视图层被同步抛出时，会阻塞调用线程（包括 main thread）。

之前用一个 `DispatchQueue.sync` + `KeychainSecureStorage` 的组合，等于把
这段阻塞时间"覆盖"掉了：调用线程等待 → 同步读 keychain → 返回。换成
**actor + Task.detached** 后：

- **真实并发**：调用方立刻拿到 `Task`，不阻塞当前隔离域（actor/SwiftUI main）。
- **可取消性**：`Task` 是结构化并发的一部分，能被上下文取消链正确传播。
- **可观测性**：未来想接 `swift-otel` / Instruments time profiler 时，符号
  名字就是 `AuthTokenStore.deviceID() async`，更容易锁定热点。

## 2. 落地范围

四层协议一并改为 `async throws`：

| 层级 | 文件 | 内容 |
|------|------|------|
| 存储原语 | `Storage/SecureStorage.swift` | `SecureStorageProtocol`、`KeychainSecureStorage`、`InMemorySecureStorage` |
| 业务协议 | `Services/AuthTokenStore.swift` | `AuthTokenStoreProtocol`、`SecureAuthTokenStore` |
| 刷新协调器 | `Services/TokenRefreshCoordinator.swift` | actor 内部调用方加 `await` |
| 三个 HTTP 客户 | `Services/Default{Speech,Daily,Corpus}*Client.swift` | 私有 `requireAccessToken/ensureAccessToken` 加 `await` |
| DI 注册 | `Dependencies/AppDependencies.swift` | `ensureGuestToken` 在 `loadBootstrap` 流程内加 `await`（已经是 async context，没有额外开销） |

所有 7 个测试 mock 同步升级：

- `MockTokenStore`（`TokenRefreshCoordinatorTests`）
- `MockTokenStore`（`AuthenticatedNetworkClientTests`）
- `InMemoryAuthTokenStore`（`DailyReadClientTests`）
- `RecordingSpeechSessionTokenStore`（`SpeechSessionClientTests`）
- `FoundationComponentsTests.inMemorySecureStorage*`（2 个）

## 3. 同步 vs 异步 — 关键决定

### 3.1 真实存储：用 `Task.detached(priority: .userInitiated)`

```swift
public func read(key: String) async throws -> Data? {
    try await Task.detached(priority: .userInitiated) {
        let query: [String: Any] = [...]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status { ... }
    }.value
}
```

为什么 `Task.detached` 而不是让 `SecureStorageProtocol` 自己是个 actor：

- **Keychain 是一次性 IPC**，让 actor 持锁反而会让一次合法的并发请求被串行化。
- `Task.detached` 不继承调用方的隔离上下文 / 优先级 / 本地 Task 变量，keychain
  错误就不会被外层 actor 的 isolation domain 误判为可重入。
- `.userInitiated` 是 UI 驱动的合理优先级（不应跑 `.background`，否则启动
  路径的 deviceID 获取会被调度器推迟，反而拉长首响）。

### 3.2 测试 fake：用 `actor`

`InMemorySecureStorage` 从 `DispatchQueue.sync` 换成 `actor` 隔离。这看起来
比 fake 需要的多，但 actor 的 reentrancy 语义与生产路径用的是同一套调度 —
不会让 mock 路径跳过 actor 重入逻辑而生产路径不会。

实际写法：

```swift
public actor InMemorySecureStorage: SecureStorageProtocol {
    private var storage: [String: Data] = [:]

    public func read(key: String) async throws -> Data? { storage[key] }
    public func write(_ data: Data, key: String) async throws { storage[key] = data }
    public func delete(key: String) async throws { storage.removeValue(forKey: key) }
}
```

> 这里不需要 `Task.detached`：actor 本身已经是隔离域，方法调用已经
> 是 hop-once，actor 内部 map 操作是纳秒级，无需额外调度。

### 3.3 协议签名：`async throws` 而不是 `() async throws -> Sendable`

`AuthTokenStoreProtocol` 保留值类型（`String`、`String?`、`Bool`、`AuthToken?`），
因为它们本来就 `Sendable`，且类型比 `Sendable & P` 抽象更利于编译器 inline。

`SecureStorageProtocol` 同理，`Data` 也是 `Sendable`。

## 4. 设计决策：是否引入 LAContext（biometric）？

**结论：本次不做。** 决策记录：

- `KeychainSecureStorage` 的现状写死了
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，等价于"L1=device unlock"，
  已经是今天在没有 Face ID/Touch ID 时的标准做法。
- 引入 `LAContext` 会把 bio-presence 检查带到每个 token 读取上，导致
  SpeakingRoom 在用户不在场时被静默失败，**对首响 P90 负面**。
- B14 的 Volcengine 集成 + 已注册用户的"敏感操作再上 LAContext"是
  后续更合适的接入点。

如果未来必须接生物识别，推荐路径：在 `SecureAuthTokenStore` 上方再叠一层
`LAContextGuardedTokenStore`，而不是改动 `SecureStorageProtocol` —
保持分层单调，避免再回退一次。

## 5. 兼容性与回退

### 5.1 二进制兼容性

- 协议方法签名变化 → **会破坏**任何下游直接实现 `AuthTokenStoreProtocol` / `SecureStorageProtocol` 的外部模块。
- 当前 internal 用户：仅 `FluentWorkCore` / `FluentWorkCoreTests`，已
  全部同步更新（`git grep AuthTokenStoreProtocol` 收得到的位置全部
  await / throws 已对齐）。
- 外部 SDK：仓库未声明 SPM 公共 SDK。下游若是 fork 仓库嵌入编译，
  升级到这次 commit 即可，没有二进制兼容承诺。

### 5.2 行为差异

- ❌ 之前：调用方同步阻塞 5-100ms，等待 keychain IPC。
- ✅ 现在：调用方立即返回 `Task`，在合适的隔离域上 hop 一次，IPC 离主。
- 没有逻辑改动，token 读写语义 / 错误抛出路径一致。

### 5.3 回退策略

如果 `Task.detached` 在某种 iOS 版本组合上 regression，最小化回退：

```swift
public func read(key: String) async throws -> Data? {
    // 旧路径：直接在当前 actor 上跑（保持 keychain 调用兼容性）
    return try performRead(key: key)
}
```

`performRead` 是把原同步 body 抽出来后 inline 调用，零架构改动，可以
作为 PR-level 灰度开关。

## 6. 验证

| 验证项 | 覆盖 |
|--------|------|
| 单元 / 集成测试 | `swift test --parallel` — **216/216** 通过 |
| 协议一致性 | `git grep "tokens\."` 仅命中 `await` 版本 |
| 调用方 | `TokenRefreshCoordinator` / `DefaultSpeechSessionClient` / `DefaultDailyReadClient` / `DefaultCorpusClient` / `ResolverBackedBootstrapClient.ensureGuestToken` 全部带 `await` |
| mock 一致性 | `MockTokenStore` × 2、`RecordingSpeechSessionTokenStore`、`InMemoryAuthTokenStore`、`FoundationComponentsTests` 全部签名对齐 |
| smoke | 真机 / 模拟器 `docs/06_第一波iPhone17Pro_Smoke_Runbook.md` 复跑（建议在下一次发版灰度前补一次） |

## 7. 后续 follow-up

不在本次 PR 范围内：

1. **`KeychainSecureStorage` 错误码转 typed error**：现在直接抛
   `SecureStorageError.unexpectedStatus(OSStatus)`，可补一张常见
   `errSec*` → `AuthStorageError.*` 的翻译表，让上层能匹配
   "keychain 锁定 / 用户拒绝 / 找不到条目"等场景。
2. **`SecureAuthTokenStore.deviceID()` 竞态写**：目前
   "read → nil → 用 idGenerator 生成 → write" 是非原子的。
   多 actor 并发启动时（例如两个 view 同时触发 bootstrap）会
   各写一遍 device_id。修正方案：把 deviceID 写挪到 actor 内部，
   或在第一次写前用 `kSecUseDataProtectionKeychain` + 自旋锁。
3. **token 缓存层（Layer 0）**：`TokenRefreshCoordinator` 已有
   1 秒的二级缓存，如果再把 "loadAccessToken 5 秒内不重读
   keychain" 加在 `SecureAuthTokenStore` 内，coordinator 路径
   可以彻底消除启动期对 keychain 的多次访问。
