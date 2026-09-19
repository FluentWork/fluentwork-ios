import FluentWorkNetworking
import Foundation

/// 传输事件路由器：将 WebSocket 事件分派到对应的处理器
///
/// Stage 1 重构目标：
/// - 将 `transportEventPump` 的巨型 switch 拆分为路由表映射
/// - 分离路由职责与业务逻辑
/// - 保持行为零变化（用现有测试锁住）
///
/// 设计原则：
/// - 路由器只负责"这个事件交给谁"，不负责业务逻辑
/// - 每个 owner 自己决定如何处理、如何计时、如何埋点
/// - 所有路由决策都是静态的、可测试的

/// 传输事件的处理结果
public enum TransportEventResult: Sendable {
    /// 事件已被处理
    case handled
    /// 事件被忽略（不是错误）
    case ignored
    /// 处理失败，需要上报
    case failed(String)
}

/// 传输事件处理器协议
public protocol TransportEventHandler: Sendable {
    func handle(event: SocketTransportEvent) async -> TransportEventResult
}

/// 音频帧处理器
public protocol AudioFrameHandler: Sendable {
    func handle(frame: WSAudioFrame) async -> TransportEventResult
}

/// 控制帧处理器
public protocol ControlFrameHandler: Sendable {
    func handle(frame: WSControlFrame) async -> TransportEventResult
}

/// 传输事件路由器
///
/// 职责：
/// 1. 根据事件类型查找对应的 handler
/// 2. 将事件分派给 handler
/// 3. 处理 handler 返回的结果
///
/// 不负责：
/// - 业务逻辑（由各 handler 实现）
/// - 计时埋点（由各 handler 实现）
/// - 错误恢复（由上层决定）
public actor TransportEventRouter {
    private let audioHandler: AudioFrameHandler?
    private let controlHandlers: [WSControlFrameType: ControlFrameHandler]
    private let diagnosticHandler: TransportEventHandler?
    private let stateChangeHandler: TransportEventHandler?
    
    public init(
        audioHandler: AudioFrameHandler? = nil,
        controlHandlers: [WSControlFrameType: ControlFrameHandler] = [:],
        diagnosticHandler: TransportEventHandler? = nil,
        stateChangeHandler: TransportEventHandler? = nil
    ) {
        self.audioHandler = audioHandler
        self.controlHandlers = controlHandlers
        self.diagnosticHandler = diagnosticHandler
        self.stateChangeHandler = stateChangeHandler
    }
    
    /// 路由并处理传输事件
    public func route(event: SocketTransportEvent) async -> TransportEventResult {
        switch event {
        case let .audio(frame):
            guard let handler = audioHandler else {
                return .ignored
            }
            return await handler.handle(frame: frame)
            
        case let .control(frame):
            let frameType = Self.frameType(of: frame)
            guard let handler = controlHandlers[frameType] else {
                return .ignored
            }
            return await handler.handle(frame: frame)
            
        case .diagnostic:
            guard let handler = diagnosticHandler else {
                return .ignored
            }
            return await handler.handle(event: event)
            
        case .stateChanged:
            guard let handler = stateChangeHandler else {
                return .ignored
            }
            return await handler.handle(event: event)
            
        case .failure:
            return .ignored
        }
    }
    
    /// 获取控制帧的类型标识（用于路由查找）
    private static func frameType(of frame: WSControlFrame) -> WSControlFrameType {
        switch frame {
        case .auth: return .auth
        case .handshake: return .handshake
        case .sessionReady: return .sessionReady
        case .sessionStart: return .sessionStart
        case .userSpeechStart: return .userSpeechStart
        case .userSpeechEnd: return .userSpeechEnd
        case .clientTurnAbort: return .clientTurnAbort
        case .clientASRTranscription: return .clientASRTranscription
        case .aiTextDelta: return .aiTextDelta
        case .aiAudioChunk: return .aiAudioChunk
        case .aiTTSStart: return .aiTTSStart
        case .aiTTSEnd: return .aiTTSEnd
        case .aiTurnEnd: return .aiTurnEnd
        case .interrupt: return .interrupt
        case .feedbackBadge: return .feedbackBadge
        case .sessionEnd: return .sessionEnd
        case .error: return .error
        case .ping: return .ping
        case .pong: return .pong
        }
    }
}

/// 控制帧类型枚举（用于路由表键）
public enum WSControlFrameType: Hashable, Sendable {
    case auth
    case handshake
    case sessionReady
    case sessionStart
    case userSpeechStart
    case userSpeechEnd
    case clientTurnAbort
    case clientASRTranscription
    case aiTextDelta
    case aiAudioChunk
    case aiTTSStart
    case aiTTSEnd
    case aiTurnEnd
    case interrupt
    case feedbackBadge
    case sessionEnd
    case error
    case ping
    case pong
}
