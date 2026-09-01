# Token 自动刷新机制实现总结

**Status**: ✅ 完成  
**Date**: 2026-09-01  
**Test Coverage**: 16/16 passing

## 实现的功能

### 1. 自动 Token 刷新
- ✅ 请求前自动检查 token 有效性
- ✅ Token 剩余时间 ≤ 5 分钟时预防性刷新
- ✅ Token 过期时自动刷新后重试请求
- ✅ 并发请求时去重刷新操作（只刷新一次）

### 2. 401 错误处理
- ✅ 自动捕获 401 错误
- ✅ 刷新 token 后自动重试（单次）
- ✅ 重试后仍失败则抛出错误（避免无限循环）

### 3. 错误处理
- ✅ 刷新失败时清理所有 token
- ✅ 强制用户重新登录（回到 guest 模式）
- ✅ 详细的错误日志

### 4. 架构清晰
- ✅ 无循环依赖（SessionAPIClient 正确使用 base client）
- ✅ Singleton 协调器确保全局唯一性
- ✅ 所有现有代码自动获得刷新能力

## 核心组件

### TokenRefreshCoordinator
**位置**: `Shared/FluentWorkCore/Services/TokenRefreshCoordinator.swift`

**职责**:
- 管理 token 刷新逻辑
- 去重并发刷新请求
- 处理 401 错误

**关键方法**:
```swift
func getValidToken() async throws -> AuthToken
func handle401Error() async throws -> AuthToken
```

### AuthenticatedNetworkClient
**位置**: `Shared/FluentWorkNetworking/AuthenticatedNetworkClient.swift`

**职责**:
- 请求前注入 Authorization header
- 请求前检查并刷新 token
- 捕获 401 错误并重试

**使用示例**:
```swift
let client = AppDependencies.shared.networkClient()
let data = try await client.requestData(for: target)
```

## 测试覆盖

### TokenRefreshCoordinatorTests (8 tests)
- ✅ 有效 token 立即返回
- ✅ 无 token 时抛出错误
- ✅ 过期 token 自动刷新
- ✅ 即将过期 token 预防性刷新
- ✅ 刷新边界条件（5 分钟）
- ✅ 并发请求去重
- ✅ 刷新失败清理 token
- ✅ 401 错误强制刷新

### AuthenticatedNetworkClientTests (5 tests)
- ✅ 请求前注入 Authorization header
- ✅ 没有 token 时抛出错误
- ✅ 即将过期 token 预刷新
- ✅ 401 错误刷新并重试
- ✅ 非 401 错误直接抛出

### TokenRefreshIntegrationTests (3 tests)
- ✅ AppDependencies 正确连接所有组件
- ✅ TokenRefreshCoordinator 是 singleton
- ✅ AuthenticatedNetworkClient 正确配置

## 现有代码兼容性

### ✅ 无需修改
所有使用 `AppDependencies.shared.networkClient()` 的代码自动获得 token 刷新能力：

- ✅ `CorpusAPIClient`
- ✅ `DailyReadAPIClient`
- ✅ `SpeechSessionClient`

### ✅ SessionAPIClient 特殊处理
- 使用 base network client（不使用 AuthenticatedNetworkClient）
- 避免循环依赖（`issueGuest` 和 `refreshToken` 本身就是认证端点）

## 关键行为

### 预防性刷新
```
Token 剩余时间 ≤ 5 分钟 → 自动刷新
目的：避免请求到达服务器时 token 已过期
```

### 并发安全
```
多个请求同时检测到过期 → 只有一个刷新请求
其他请求 → 等待刷新完成后共享新 token
```

### 单次重试
```
收到 401 → 刷新 token → 重试请求
重试后仍 401 → 直接失败（避免无限循环）
```

### 错误降级
```
刷新失败 → 清理所有 token → 回到 guest 模式
```

## 使用示例

### 1. 普通 API 调用
```swift
// Token 自动处理，无需关心细节
let client = AppDependencies.shared.networkClient()
let response = try await client.request(for: MyTarget.getData)
```

### 2. 手动获取有效 token
```swift
let coordinator = AppDependencies.shared.tokenRefreshCoordinator()
let token = try await coordinator.getValidToken()
print(token.value) // "eyJhbGc..."
```

### 3. 处理认证失败
```swift
do {
    let result = try await someAPICall()
} catch APIError.backend(code: "http_401", _) {
    // AuthenticatedNetworkClient 已经尝试过刷新
    // 这里意味着刷新也失败了，应该引导用户重新登录
    showLoginScreen()
}
```

## 性能特征

- **零额外延迟**: Token 有效时无额外网络请求
- **预防性刷新**: 避免请求中途 token 过期
- **并发优化**: 多请求共享单次刷新
- **单次重试**: 最多 2 倍延迟（原请求 + 重试）

## 日志示例

```
[🔑 Token] Using cached token: access-1...
[🔑 Token] Token expires in 4.5 minutes, refreshing...
[🔑 Token] Successfully refreshed token
[🔑 Token] Saved token to keychain
[🔑 Token] Request received 401, attempting refresh and retry
```

## 未来扩展

### Refresh Token 支持
如果需要支持 refresh token（与 access token 分离）：

1. 扩展 `AuthTokenStore` 存储 refresh token
2. 修改 `TokenRefreshCoordinator.refreshTokenIfNeeded()` 使用 refresh token
3. 更新 `SessionAPIClient.refreshToken()` API 签名

### Token 状态监听
可以添加 Combine publisher 用于 UI 监听：

```swift
extension TokenRefreshCoordinator {
    var tokenStatePublisher: AnyPublisher<TokenState, Never>
}

enum TokenState {
    case valid
    case refreshing
    case expired
    case refreshFailed(Error)
}
```

## 文档

- 📄 [完整实现文档](./token-refresh-implementation.md)
- 📄 [架构设计](./token-refresh-implementation.md#architecture)
- 📄 [测试策略](./token-refresh-implementation.md#test-strategy)

## 结论

✅ Token 自动刷新机制完整实现  
✅ 16/16 测试通过  
✅ 无破坏性改动  
✅ 所有现有 API clients 自动受益  
✅ 架构清晰，易于维护

**可以合并到主分支** 🚀
