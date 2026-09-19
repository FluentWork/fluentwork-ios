import FluentWorkNetworking
import Foundation

/// 传输事件路由器：把一个 WebSocket 事件交给它所属的 handler。
///
/// ## 它做什么
///
/// 只做路由。一个事件进来，按类型找一个 handler，交给它。"这类帧归谁"从
/// 一个 237 行的 switch 挪进一张可断言的静态路由表，也就不再有一条谁都可能
/// 动到的 `default` 分支在底下兜着。
///
/// ## 它不做什么
///
/// 不碰业务、不碰计时埋点、不碰错误恢复。每个 handler 自己决定怎么处理、
/// 怎么埋点、失败时往哪里报——失败的落点由 handler 自己 dispatch，不经过
/// 这里。这也正是这个类型能停在 150 行的原因。
///
/// ## 为什么是 struct，不是 actor
///
/// 四个字段全是 `let`，没有状态。唯一的调用者是一条 `for await` 串行循环，
/// 本来就在每个事件上 `await`——actor 在这里只提供调用方已经自己保证了的
/// 串行性。代价却是**每个音频帧一次额外的 actor 跳转**，而音频是一帧一个
/// 事件：一个 250 帧的回合就是 250 次跳转、250 个挂起点，正压在延迟最敏感
/// 的那条路上。
///
/// ## 一个调用者，一次一个事件
///
/// 路由本身不做同步，也不需要：调用方是串行的。handler 体内**不得**派生任务
/// （`Task {}` / `async let` / `withTaskGroup` / `Task.detached`）——`for await`
/// 的逐事件串行性来自循环自己 `await`，一旦 detach 就消失了，而没有任何测试
/// 会因此变红。
public struct TransportEventRouter: Sendable {
    private let audioHandler: AudioFrameHandler?
    private let controlHandlers: [WSControlFrameType: ControlFrameHandler]
    private let diagnosticHandler: TransportEventHandler?
    /// 兜住没有专属 handler 的事件。
    ///
    /// 这一个槽位同时承载三件今天都落在 pump 的 `default` 臂里的事：
    /// `.stateChanged`、`.failure`、以及**没有注册 handler 的控制帧**。
    ///
    /// 把这些合成一个槽位而不是各给一个，是因为它们今天的处理方式本来就相同
    /// （都交给 `SocketTransportEventMapper`）。而 `.failure` 单独硬编码成
    /// "忽略"曾经正是这里的缺陷：socket 断了，什么都不发生。
    private let fallbackHandler: TransportEventHandler?

    public init(
        audioHandler: AudioFrameHandler? = nil,
        controlHandlers: [WSControlFrameType: ControlFrameHandler] = [:],
        diagnosticHandler: TransportEventHandler? = nil,
        fallbackHandler: TransportEventHandler? = nil
    ) {
        self.audioHandler = audioHandler
        self.controlHandlers = controlHandlers
        self.diagnosticHandler = diagnosticHandler
        self.fallbackHandler = fallbackHandler
    }

    /// 路由一个事件。
    ///
    /// 没有返回值：路由不产生决定。handler 的产出是它自己的 dispatch 与埋点，
    /// 路由器无从判断那算不算"处理成功"，一个表达不了任何东西的结果类型只会
    /// 逼每个 handler 写 `return .handled`。
    public func route(event: SocketTransportEvent) async {
        switch event {
        case let .audio(frame):
            if let handler = audioHandler {
                await handler.handle(frame: frame)
                return
            }
            await Self.forward(fallbackHandler, event)

        case let .control(frame):
            if let handler = controlHandlers[frame.wireType] {
                await handler.handle(frame: frame)
                return
            }
            await Self.forward(fallbackHandler, event)

        case .diagnostic:
            if let handler = diagnosticHandler {
                await handler.handle(event: event)
                return
            }
            await Self.forward(fallbackHandler, event)

        case .stateChanged, .failure:
            await Self.forward(fallbackHandler, event)
        }
    }

    private static func forward(_ handler: TransportEventHandler?, _ event: SocketTransportEvent) async {
        guard let handler else {
            return
        }
        await handler.handle(event: event)
    }
}

/// 传输事件处理器。
///
/// 返回 `Void`，不是"处理结果"：处理成不成功由 handler 自己决定并自己 dispatch，
/// 路由器既没有能力判断，也没有消费者去读它。
public protocol TransportEventHandler: Sendable {
    func handle(event: SocketTransportEvent) async
}

/// 音频帧处理器。
public protocol AudioFrameHandler: Sendable {
    func handle(frame: WSAudioFrame) async
}

/// 控制帧处理器。
public protocol ControlFrameHandler: Sendable {
    func handle(frame: WSControlFrame) async
}

// MARK: - 闭包适配器

/// 把闭包套上协议外壳，好让 handler 定义在使用它的地方。
///
/// 这些是**适配器，不是 owner 类型**：它们没有状态、没有逻辑、不聚合任何职责。
/// 中间件用它们把每个 handler 写成一段就地闭包，从而捕获它本来就能拿到的
/// `dispatchBox` / `tracker` / `timings`，而不必为此发明一层新的转发对象。

public struct AnyTransportEventHandler: TransportEventHandler {
    private let body: @Sendable (SocketTransportEvent) async -> Void

    public init(_ body: @escaping @Sendable (SocketTransportEvent) async -> Void) {
        self.body = body
    }

    public func handle(event: SocketTransportEvent) async {
        await body(event)
    }
}

public struct AnyAudioFrameHandler: AudioFrameHandler {
    private let body: @Sendable (WSAudioFrame) async -> Void

    public init(_ body: @escaping @Sendable (WSAudioFrame) async -> Void) {
        self.body = body
    }

    public func handle(frame: WSAudioFrame) async {
        await body(frame)
    }
}

public struct AnyControlFrameHandler: ControlFrameHandler {
    private let body: @Sendable (WSControlFrame) async -> Void

    public init(_ body: @escaping @Sendable (WSControlFrame) async -> Void) {
        self.body = body
    }

    public func handle(frame: WSControlFrame) async {
        await body(frame)
    }
}
