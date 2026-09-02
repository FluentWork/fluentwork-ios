import Foundation
import FluentWorkNetworking

/// Token 刷新协调器，管理 token 生命周期和刷新逻辑
///
/// 职责：
/// - 检查 token 是否即将过期（5 分钟内）
/// - 协调 token 刷新，防止并发刷新（惊群问题）
/// - 处理刷新失败并清理过期 token
public actor TokenRefreshCoordinator {
    // MARK: - Dependencies
    
    private let tokenStore: AuthTokenStoreProtocol
    private let sessionAPI: SessionAPIClientProtocol
    private let expiryBuffer: TimeInterval
    private let currentTime: @Sendable () -> Date
    
    // MARK: - State
    
    /// 当前正在进行的刷新任务（用于防止并发刷新）
    private var refreshTask: Task<AuthToken, Error>?
    
    /// 缓存的 token 及其检查时间（避免重复检查）
    private var cachedTokenCheck: (token: AuthToken, checkedAt: Date)?
    
    // MARK: - Initialization
    
    public init(
        tokenStore: AuthTokenStoreProtocol,
        sessionAPI: SessionAPIClientProtocol,
        expiryBuffer: TimeInterval = 5 * 60, // 默认 5 分钟
        currentTime: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.sessionAPI = sessionAPI
        self.expiryBuffer = expiryBuffer
        self.currentTime = currentTime
    }
    
    // MARK: - Public API
    
    /// 获取有效的 access token
    ///
    /// 如果当前 token 即将过期（在 expiryBuffer 时间内），会自动刷新
    ///
    /// - Returns: 有效的 access token
    /// - Throws: `TokenError.noToken` 如果没有 token
    ///          `TokenError.refreshFailed` 如果刷新失败
    public func getValidToken() async throws -> AuthToken {
        let now = currentTime()
        
        // 1. 检查缓存（避免在短时间内重复检查同一个 token）
        if let cached = cachedTokenCheck,
           cached.checkedAt.timeIntervalSince(now) > -1.0 { // 1 秒内的检查结果可复用
            let timeUntilExpiry = cached.token.expiresAt.timeIntervalSince(now)
            if timeUntilExpiry > expiryBuffer {
                return cached.token
            }
        }
        
        // 2. 尝试从 store 获取 token
        guard let token = try await tokenStore.loadAccessToken() else {
            cachedTokenCheck = nil
            throw TokenError.noToken
        }
        
        // 3. 检查是否即将过期
        let timeUntilExpiry = token.expiresAt.timeIntervalSince(now)
        
        if timeUntilExpiry > expiryBuffer {
            // Token 仍然有效，缓存检查结果并返回
            cachedTokenCheck = (token, now)
            return token
        }
        
        // 4. Token 即将过期，需要刷新
        cachedTokenCheck = nil // 清除缓存
        return try await refreshTokenIfNeeded(currentToken: token)
    }
    
    /// 处理 401 错误，强制刷新 token
    ///
    /// 用于 HTTP interceptor 在收到 401 响应时调用
    ///
    /// - Returns: 刷新后的新 token
    /// - Throws: `TokenError.noToken` 如果没有 token
    ///          `TokenError.refreshFailed` 如果刷新失败
    public func handle401Error() async throws -> AuthToken {
        cachedTokenCheck = nil // 清除缓存，因为 token 已经无效
        
        guard let token = try await tokenStore.loadAccessToken() else {
            throw TokenError.noToken
        }

        // 强制刷新（忽略过期时间）
        return try await refreshTokenIfNeeded(currentToken: token, force: true)
    }
    
    // MARK: - Private Helpers
    
    /// 刷新 token（如果需要）
    ///
    /// 如果已经有刷新任务在进行，会等待现有任务完成（防止惊群）
    ///
    /// - Parameters:
    ///   - currentToken: 当前的 token
    ///   - force: 是否强制刷新（忽略过期检查）
    /// - Returns: 刷新后的新 token
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
                // 调用 API 刷新 token
                let newToken = try await sessionAPI.refreshToken(currentToken.value)

                // 保存新 token
                try await tokenStore.saveAccessToken(newToken)

                // 更新缓存
                cachedTokenCheck = (newToken, currentTime())

                return newToken
            } catch {
                // 刷新失败，清理所有 token（强制重新登录）
                try? await tokenStore.clear()
                cachedTokenCheck = nil
                throw TokenError.refreshFailed(underlying: error)
            }
        }
        
        refreshTask = task
        
        defer {
            // 任务完成后清理状态
            refreshTask = nil
        }
        
        return try await task.value
    }
}

// MARK: - Error Types

public enum TokenError: Error, Equatable {
    case noToken
    case refreshFailed(underlying: Error?)
    case expired
    
    public static func == (lhs: TokenError, rhs: TokenError) -> Bool {
        switch (lhs, rhs) {
        case (.noToken, .noToken):
            return true
        case (.refreshFailed, .refreshFailed):
            return true
        case (.expired, .expired):
            return true
        default:
            return false
        }
    }
}
