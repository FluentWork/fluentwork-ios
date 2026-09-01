# Token 刷新与错误处理技术方案

## 1. 问题概述

当前系统存在以下 token 管理问题：

1. **无主动刷新机制**：Token 即将过期时不会自动刷新，导致用户请求失败
2. **401 错误处理缺失**：服务端返回 401 时，客户端没有统一的重试逻辑
3. **API 惊群问题**：多个并发请求同时发现 token 过期时，会同时发起刷新请求

## 2. 技术目标

### 2.1 核心目标
- ✅ Token 过期前 5 分钟自动刷新
- ✅ 401 错误统一处理和重试
- ✅ 防止并发刷新（惊群问题）
- ✅ 刷新失败后清理 token 并重新登录

### 2.2 非目标
- ❌ 不处理网络连接问题（由 NetworkConnectivityFeature 处理）
- ❌ 不处理其他 HTTP 错误码（4xx/5xx 由业务层处理）

## 3. 架构设计

### 3.1 Token 生命周期状态机

```
┌─────────────┐
│   No Token  │
└──────┬──────┘
       │ 获取 token
       ↓
┌─────────────┐     过期前 5 分钟      ┌─────────────┐
│    Valid    │ ──────────────────→    │  Refreshing │
└──────┬──────┘                        └──────┬──────┘
       │                                      │
       │ 401 错误                             │ 刷新成功
       ↓                                      ↓
┌─────────────┐                        ┌─────────────┐
│   Expired   │ ←────── 刷新失败 ──────│    Valid    │
└──────┬──────┘                        └─────────────┘
       │
       │ 清理并重新获取
       ↓
┌─────────────┐
│   No Token  │
└─────────────┘
```

### 3.2 组件职责划分

#### TokenRefreshCoordinator
- **职责**：Token 刷新的核心协调器
- **功能**：
  - 管理刷新状态（防惊群）
  - 提供 `getValidToken()` 方法，自动检查过期和刷新
  - 处理刷新失败后的清理

```swift
public actor TokenRefreshCoordinator {
    private let tokenStore: AuthTokenStoreProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let expiryBuffer: TimeInterval = 5 * 60 // 5 分钟
    
    private var refreshTask: Task<AuthToken, Error>?
    
    /// 获取有效 token，如果即将过期则自动刷新
    public func getValidToken() async throws -> AuthToken
    
    /// 处理 401 错误，尝试刷新并重试
    public func handle401Error() async throws -> AuthToken
    
    /// 清理刷新状态
    private func clearRefreshState()
}
```

#### HTTP Interceptor
- **职责**：拦截所有 HTTP 请求和响应
- **功能**：
  - 请求前注入 token（通过 `getValidToken()`）
  - 响应 401 时调用 `handle401Error()` 并重试
  - 重试失败后抛出错误

```swift
public struct TokenRefreshInterceptor: HTTPInterceptor {
    private let coordinator: TokenRefreshCoordinator
    private let maxRetries: Int = 1
    
    public func intercept(
        request: URLRequest,
        next: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse)
}
```

## 4. 详细实现

### 4.1 TokenRefreshCoordinator 实现

```swift
public actor TokenRefreshCoordinator {
    private let tokenStore: AuthTokenStoreProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let expiryBuffer: TimeInterval
    private let currentTime: @Sendable () -> Date
    
    private var refreshTask: Task<AuthToken, Error>?
    
    public init(
        tokenStore: AuthTokenStoreProtocol,
        sessionAPI: SessionAPIClientProtocol,
        expiryBuffer: TimeInterval = 5 * 60,
        currentTime: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.sessionAPI = sessionAPI
        self.expiryBuffer = expiryBuffer
        self.currentTime = currentTime
    }
    
    /// 获取有效 token，如果即将过期则自动刷新
    public func getValidToken() async throws -> AuthToken {
        // 1. 尝试从 store 获取 token
        guard let token = try tokenStore.loadAccessToken() else {
            throw TokenError.noToken
        }
        
        // 2. 检查是否即将过期（5 分钟内）
        let now = currentTime()
        let timeUntilExpiry = token.expiresAt.timeIntervalSince(now)
        
        if timeUntilExpiry > expiryBuffer {
            // Token 仍然有效，直接返回
            return token
        }
        
        // 3. Token 即将过期，需要刷新
        return try await refreshTokenIfNeeded(currentToken: token)
    }
    
    /// 处理 401 错误，尝试刷新并重试
    public func handle401Error() async throws -> AuthToken {
        guard let token = try tokenStore.loadAccessToken() else {
            throw TokenError.noToken
        }
        
        // 强制刷新
        return try await refreshTokenIfNeeded(currentToken: token, force: true)
    }
    
    private func refreshTokenIfNeeded(
        currentToken: AuthToken,
        force: Bool = false
    ) async throws -> AuthToken {
        // 如果已经有刷新任务在进行，等待它完成（防惊群）
        if let existingTask = refreshTask {
            return try await existingTask.value
        }
        
        // 创建新的刷新任务
        let task = Task<AuthToken, Error> {
            do {
                let newToken = try await sessionAPI.refreshToken(currentToken.value)
                try tokenStore.saveAccessToken(newToken)
                return newToken
            } catch {
                // 刷新失败，清理 token
                try? tokenStore.clearAllTokens()
                throw error
            }
        }
        
        refreshTask = task
        
        defer {
            // 任务完成后清理
            refreshTask = nil
        }
        
        return try await task.value
    }
}

public enum TokenError: Error {
    case noToken
    case refreshFailed
    case expired
}
```

### 4.2 HTTP Interceptor 实现

```swift
public struct TokenRefreshInterceptor: HTTPInterceptor {
    private let coordinator: TokenRefreshCoordinator
    private let maxRetries: Int
    
    public init(
        coordinator: TokenRefreshCoordinator,
        maxRetries: Int = 1
    ) {
        self.coordinator = coordinator
        self.maxRetries = maxRetries
    }
    
    public func intercept(
        request: URLRequest,
        next: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        var attemptCount = 0
        
        while attemptCount <= maxRetries {
            // 1. 获取有效 token 并注入请求
            let token = try await coordinator.getValidToken()
            var authenticatedRequest = request
            authenticatedRequest.setValue(
                "Bearer \(token.value)",
                forHTTPHeaderField: "Authorization"
            )
            
            // 2. 执行请求
            let (data, response) = try await next(authenticatedRequest)
            
            // 3. 检查响应
            guard let httpResponse = response as? HTTPURLResponse else {
                return (data, response)
            }
            
            // 4. 如果是 401 且还有重试次数
            if httpResponse.statusCode == 401 && attemptCount < maxRetries {
                // 尝试刷新 token 并重试
                _ = try await coordinator.handle401Error()
                attemptCount += 1
                continue
            }
            
            // 5. 返回响应
            return (data, response)
        }
        
        // 重试次数用尽
        throw TokenError.refreshFailed
    }
}
```

### 4.3 SessionAPIClient 集成

```swift
public struct SessionAPIClient: SessionAPIClientProtocol {
    private let baseURL: URL
    private let httpClient: HTTPClient
    private let decoder: JSONDecoder
    
    // 现有的初始化器保持不变
    
    /// 新增：支持 interceptor 的初始化器
    public init(
        baseURL: URL,
        interceptors: [HTTPInterceptor] = [],
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.baseURL = baseURL
        self.httpClient = HTTPClient(interceptors: interceptors)
        self.decoder = decoder
    }
    
    // refreshToken 方法实现
    public func refreshToken(_ token: String) async throws -> AuthToken {
        let url = baseURL.appendingPathComponent("/api/auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await httpClient.execute(request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TokenError.refreshFailed
        }
        
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
        return AuthToken(
            value: tokenResponse.accessToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(tokenResponse.expiresAt))
        )
    }
}
```

## 5. 集成点

### 5.1 AppDependencies 更新

```swift
public struct AppDependencies {
    // 现有依赖...
    
    public let tokenRefreshCoordinator: TokenRefreshCoordinator
    
    public init(...) {
        // 1. 创建 token store
        self.tokenStore = AuthTokenStore(...)
        
        // 2. 创建 session API（先不带 interceptor）
        let sessionAPIWithoutInterceptor = SessionAPIClient(baseURL: ...)
        
        // 3. 创建 refresh coordinator
        self.tokenRefreshCoordinator = TokenRefreshCoordinator(
            tokenStore: tokenStore,
            sessionAPI: sessionAPIWithoutInterceptor
        )
        
        // 4. 创建带 interceptor 的 session API
        let interceptor = TokenRefreshInterceptor(
            coordinator: tokenRefreshCoordinator
        )
        self.sessionAPI = SessionAPIClient(
            baseURL: baseURL,
            interceptors: [interceptor]
        )
        
        // 其他依赖...
    }
}
```

### 5.2 测试策略

#### 单元测试
```swift
@Test func tokenRefreshCoordinator_validToken_returnsImmediately() async throws {
    // Given: Token 还有 10 分钟过期
    let futureExpiry = Date().addingTimeInterval(10 * 60)
    let token = AuthToken(value: "valid", expiresAt: futureExpiry)
    tokenStore.saveAccessToken(token)
    
    // When: 获取 token
    let result = try await coordinator.getValidToken()
    
    // Then: 直接返回，不刷新
    #expect(result.value == "valid")
    #expect(sessionAPI.refreshTokenCallCount == 0)
}

@Test func tokenRefreshCoordinator_expiringSoon_refreshesToken() async throws {
    // Given: Token 还有 3 分钟过期
    let soonExpiry = Date().addingTimeInterval(3 * 60)
    let token = AuthToken(value: "old", expiresAt: soonExpiry)
    tokenStore.saveAccessToken(token)
    
    sessionAPI.refreshTokenStub = AuthToken(
        value: "new",
        expiresAt: Date().addingTimeInterval(60 * 60)
    )
    
    // When: 获取 token
    let result = try await coordinator.getValidToken()
    
    // Then: 刷新并返回新 token
    #expect(result.value == "new")
    #expect(sessionAPI.refreshTokenCallCount == 1)
}

@Test func tokenRefreshCoordinator_concurrentRequests_onlyRefreshOnce() async throws {
    // Given: Token 即将过期
    let soonExpiry = Date().addingTimeInterval(3 * 60)
    let token = AuthToken(value: "old", expiresAt: soonExpiry)
    tokenStore.saveAccessToken(token)
    
    // When: 10 个并发请求
    await withTaskGroup(of: AuthToken.self) { group in
        for _ in 0..<10 {
            group.addTask {
                try! await coordinator.getValidToken()
            }
        }
    }
    
    // Then: 只刷新一次
    #expect(sessionAPI.refreshTokenCallCount == 1)
}
```

#### 集成测试
```swift
@Test func httpInterceptor_401Response_refreshesAndRetries() async throws {
    // Given: 配置 mock server 返回 401 然后成功
    mockServer.responses = [
        .failure(statusCode: 401),
        .success(data: validData)
    ]
    
    // When: 发起请求
    let result = try await httpClient.get("/api/data")
    
    // Then: 自动刷新并重试成功
    #expect(result == validData)
    #expect(coordinator.handle401ErrorCallCount == 1)
    #expect(mockServer.requestCount == 2)
}
```

## 6. 实施计划

### Phase 3: Token 刷新基础设施（1 天）
- [ ] 实现 `TokenRefreshCoordinator`
- [ ] 实现 `TokenRefreshInterceptor`
- [ ] 单元测试覆盖核心逻辑
- [ ] 构建验证

### Phase 4: API 集成（1 天）
- [ ] `SessionAPIClient` 添加 `refreshToken` 方法
- [ ] 更新 `AppDependencies` 集成 coordinator
- [ ] 集成测试验证完整流程
- [ ] 端到端测试（真实服务器）

### Phase 5: 错误处理优化（0.5 天）
- [ ] 添加详细的错误日志
- [ ] 添加 Sentry 错误上报
- [ ] 监控刷新成功率指标

## 7. 风险和缓解

### 7.1 刷新 API 不存在
- **风险**：后端可能还没实现 refresh token API
- **缓解**：
  1. 先与后端确认 API 是否存在
  2. 如果不存在，降级为 401 时清理 token 并重新登录

### 7.2 循环刷新
- **风险**：刷新 API 返回的 token 仍然过期
- **缓解**：添加刷新次数限制（最多 1 次）

### 7.3 性能影响
- **风险**：每个请求都检查过期时间
- **缓解**：过期检查是简单的时间比较，性能开销可忽略

## 8. 监控指标

建议添加以下指标：
- Token 刷新成功率
- Token 刷新延迟
- 401 错误率
- 刷新失败后的降级次数

## 9. 后续优化

### 9.1 Refresh Token 支持
当前方案使用 access token 刷新，后续可支持专用的 refresh token：
```swift
struct TokenPair {
    let accessToken: AuthToken
    let refreshToken: String
}
```

### 9.2 多租户支持
如果需要支持多账号，coordinator 可以按 userID 隔离：
```swift
actor TokenRefreshCoordinatorPool {
    private var coordinators: [String: TokenRefreshCoordinator] = [:]
    
    func coordinator(for userID: String) -> TokenRefreshCoordinator
}
```

## 10. 决策记录

| 决策 | 理由 |
|------|------|
| 使用 Actor 而非锁 | Swift 6 并发安全，更符合现代实践 |
| 5 分钟过期缓冲 | 平衡刷新频率和安全性 |
| 最多重试 1 次 | 避免无限循环，快速失败 |
| Interceptor 模式 | 集中处理，不污染业务代码 |
| 刷新失败清理 token | 强制用户重新登录，保证状态一致 |
