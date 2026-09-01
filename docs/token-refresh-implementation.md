# Token Refresh Implementation

## Overview

实现了自动 token 刷新机制，确保所有 HTTP 请求都使用有效的 access token，并在 token 过期或收到 401 错误时自动刷新。

## Architecture

### 1. TokenRefreshCoordinator

**职责**: 集中管理 token 刷新逻辑

**核心功能**:
- `getValidToken()`: 获取有效 token，必要时自动刷新
- `handle401Error()`: 处理 401 错误，强制刷新 token
- 防止并发请求导致的重复刷新（使用 Task 同步）
- 在刷新失败时清理所有 token

**关键设计**:
```swift
// 时间缓冲：提前 5 分钟刷新
private let expiryBuffer: TimeInterval = 5 * 60

// 并发控制：同一时间只有一个刷新任务
private var ongoingRefreshTask: Task<AuthToken, Error>?
```

### 2. AuthenticatedNetworkClient

**职责**: 为所有 HTTP 请求注入认证 token，处理 401 错误

**性能优化**:
- Actor-isolated 本地缓存（1 秒 TTL）
- 避免对 TokenRefreshCoordinator 的重复调用
- 401 错误时清除本地缓存并强制刷新

**关键流程**:
```
1. 预检查：调用 getValidTokenWithCache() 确保 token 有效
   - 优先使用本地缓存（避免跨 actor 调用）
   - 缓存未命中时调用 coordinator.getValidToken()
2. 注入 header：添加 Authorization header
3. 发送请求
4. 如果收到 401：
   - 清除本地缓存
   - 调用 coordinator.handle401Error() 强制刷新
   - 用新 token 重试请求（只重试一次）
5. 其他错误直接抛出
```

### 3. 依赖关系

**关键修复：打破循环依赖**

原问题：
```
networkClient → tokenRefreshCoordinator → sessionAPIClient → networkClient (循环！)
```

解决方案：
- `SessionAPIClient` 使用 **base network client**（不带认证拦截器）
- 因为 `issueGuest` 和 `refreshToken` 本身就是获取 token 的接口，不需要认证

```swift
// AppDependencies.swift
var sessionAPIClient: Factory<SessionAPIClientProtocol> {
    self {
        // Use base client to avoid circular dependency
        let baseClient = self.networkPluginFactory().makeNetworkClient()
        return SessionAPIClient(
            network: baseClient,
            baseURL: self.appEnvironment().apiBaseURL
        )
    }.singleton
}

var networkClient: Factory<NetworkClientProtocol> {
    self {
        let baseClient = self.networkPluginFactory().makeNetworkClient()
        return AuthenticatedNetworkClient(
            baseClient: baseClient,
            tokenRefreshCoordinator: self.tokenRefreshCoordinator()
        )
    }.singleton
}

var tokenRefreshCoordinator: Factory<TokenRefreshCoordinator> {
    self {
        TokenRefreshCoordinator(
            tokenStore: self.authTokenStore(),
            sessionAPI: self.sessionAPIClient()
        )
    }.singleton
}
```

## Test Coverage

### TokenRefreshCoordinatorTests (8 tests)
- ✅ 有效 token 直接返回
- ✅ 已过期 token 自动刷新
- ✅ 即将过期 token 自动刷新
- ✅ 边界条件处理（正好 5 分钟）
- ✅ 并发请求只刷新一次
- ✅ 没有 token 抛出错误
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

**Total: 16/16 tests passing ✅**

## Usage Examples

### 1. 普通 API 调用（自动处理 token）

```swift
// 使用 AuthenticatedNetworkClient
let client = AppDependencies.shared.networkClient()

// token 自动注入，过期自动刷新，401 自动重试
let data = try await client.requestData(for: target)
```

### 2. 手动获取 token

```swift
let coordinator = AppDependencies.shared.tokenRefreshCoordinator()

// 获取有效 token（必要时自动刷新）
let token = try await coordinator.getValidToken()
print(token.value) // "eyJhbGc..."
```

### 3. 处理 401 错误

```swift
// AuthenticatedNetworkClient 自动处理，无需手动干预
// 如果需要手动处理：
do {
    let result = try await someAPICall()
} catch APIError.backend(code: "http_401", _) {
    let newToken = try await coordinator.handle401Error()
    // 用新 token 重试
}
```

## Key Behaviors

### 预防性刷新
- Token 剩余时间 ≤ 5 分钟时自动刷新
- 避免请求到达服务器时 token 已过期

### 并发安全
- 多个请求同时发现 token 过期时，只有一个刷新请求
- 其他请求等待刷新完成后共享新 token

### 单次重试
- 收到 401 时刷新 token 并重试
- 重试后仍然 401 则直接失败（避免无限循环）

### 错误处理
- 刷新失败时清理所有 token
- 强制用户重新登录（回到 guest 模式）

## Implementation Files

### Core
- `Shared/FluentWorkCore/Services/TokenRefreshCoordinator.swift` - 刷新协调器
- `Shared/FluentWorkNetworking/AuthenticatedNetworkClient.swift` - 认证网络客户端

### Tests
- `Tests/FluentWorkCoreTests/Services/TokenRefreshCoordinatorTests.swift`
- `Tests/FluentWorkCoreTests/Services/AuthenticatedNetworkClientTests.swift`
- `Tests/FluentWorkCoreTests/Services/TokenRefreshIntegrationTests.swift`

### Configuration
- `Shared/FluentWorkCore/Dependencies/AppDependencies.swift` - 依赖注入配置

## Migration Notes

### 现有代码无需修改
- 所有使用 `AppDependencies.shared.networkClient()` 的代码自动获得 token 刷新能力
- 无需修改 API 调用代码

### 已验证的 API Clients
以下 clients 已经使用 `networkClient()`，自动支持 token 刷新：
- ✅ `CorpusAPIClient`
- ✅ `DailyReadAPIClient`
- ✅ `SpeechSessionClient`

### 特殊情况：SessionAPIClient
- ❌ **不使用** `AuthenticatedNetworkClient`
- ✅ 使用 base network client（避免循环依赖）
- ✅ 这是正确的：`issueGuest` 和 `refreshToken` 不需要认证

## Future Considerations

### Refresh Token 支持
当前实现使用 access token 刷新。如果将来需要 refresh token：

1. 扩展 `AuthTokenStore` 存储 refresh token
2. 修改 `TokenRefreshCoordinator.refreshTokenIfNeeded()` 使用 refresh token
3. 更新 `SessionAPIClient.refreshToken()` 接口

### Token 过期通知
可以添加 Combine publisher 通知 token 状态变化：

```swift
extension TokenRefreshCoordinator {
    var tokenStatePublisher: AnyPublisher<TokenState, Never> { ... }
}

enum TokenState {
    case valid
    case refreshing
    case expired
    case refreshFailed(Error)
}
```

### 性能优化
- 考虑在 token 刷新时缓存待发送的请求
- 避免重复检查 token 有效性

## Conclusion

✅ Token 自动刷新机制已完整实现并通过所有测试  
✅ 所有现有 API clients 自动获得 token 刷新能力  
✅ 无循环依赖，架构清晰  
✅ 并发安全，错误处理完善  
✅ 16/16 tests passing
