# 架构总览与分层设计

**日期**: 2026-09-21  
**目标**: 定义 iOS TTS WebSocket 系统的整体架构、分层模型与核心组件

---

## 一、架构总览

### 1.1 系统边界

```
┌─────────────────────────────────────────────────────────┐
│                     iOS Application                      │
│  ┌───────────────────────────────────────────────────┐  │
│  │              Presentation Layer                    │  │
│  │         (SwiftUI Views + ViewModels)              │  │
│  └─────────────────┬─────────────────────────────────┘  │
│                    │                                     │
│  ┌─────────────────▼─────────────────────────────────┐  │
│  │               Domain Layer                         │  │
│  │        (Business Logic + State Machine)           │  │
│  └─────────────────┬─────────────────────────────────┘  │
│                    │                                     │
│  ┌─────────────────▼─────────────────────────────────┐  │
│  │            Infrastructure Layer                    │  │
│  │    (WebSocket + Audio Engine + Protocols)         │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                         │
                         │ WSS (TLS)
                         │
                    ┌────▼────┐
                    │ Backend │
                    │ Server  │
                    └─────────┘
```

### 1.2 设计哲学

**Clean Architecture + MVVM + Actor**:
- **分层隔离**: 每层只依赖下层，上层变化不影响下层
- **依赖倒置**: 业务逻辑不依赖具体实现，通过协议抽象
- **接缝驱动**: 每个关键组件都可被测试替身替换
- **并发安全**: Actor 保护状态，async/await 控制流

---

## 二、三层架构

### 2.1 Presentation Layer (表示层)

**职责**:
- 用户交互（按钮点击、手势识别）
- 状态展示（文本、动画、波形）
- 导航控制（页面跳转）

**核心组件**:

```swift
// MARK: - SwiftUI Views

/// 主对话视图
struct ConversationView: View {
    @StateObject var viewModel: ConversationViewModel
    
    var body: some View {
        VStack {
            // 对话历史
            ScrollView {
                ForEach(viewModel.turns) { turn in
                    TurnView(turn: turn)
                }
            }
            
            // 实时状态
            StatusView(state: viewModel.sessionState)
            
            // 录音按钮
            RecordButton(
                isRecording: viewModel.isRecording,
                onPress: { await viewModel.startRecording() },
                onRelease: { await viewModel.stopRecording() }
            )
        }
    }
}

// MARK: - ViewModel

/// 对话视图模型
@MainActor
class ConversationViewModel: ObservableObject {
    // 状态
    @Published var turns: [Turn] = []
    @Published var sessionState: SessionState = .idle
    @Published var isRecording: Bool = false
    
    // 依赖注入
    private let sessionService: VoiceSessionService
    
    init(sessionService: VoiceSessionService) {
        self.sessionService = sessionService
        observeSessionUpdates()
    }
    
    // 用户操作
    func startRecording() async {
        await sessionService.startRecording()
    }
    
    func stopRecording() async {
        await sessionService.stopRecording()
    }
    
    func interrupt() async {
        await sessionService.interrupt()
    }
    
    // 观察状态变化
    private func observeSessionUpdates() {
        Task {
            for await update in sessionService.updates {
                handleUpdate(update)
            }
        }
    }
}
```

**设计要点**:
- ViewModel 持有 Service，View 持有 ViewModel
- ViewModel 是 `@MainActor`，保证 UI 更新在主线程
- 使用 `@Published` 自动触发 UI 刷新
- 异步操作使用 `async/await`

### 2.2 Domain Layer (业务层)

**职责**:
- 会话生命周期管理
- 对话状态机
- 业务规则执行
- 错误处理策略

**核心组件**:

```swift
// MARK: - Voice Session Service

/// 语音会话服务（核心业务逻辑）
actor VoiceSessionService {
    // 状态
    private var state: SessionState = .idle
    private var currentTurnID: String?
    private var sessionID: String?
    
    // 依赖
    private let transport: WebSocketTransport
    private let audioEngine: AudioEngine
    private let stateManager: SessionStateManager
    
    // 事件流
    private let updateStream: AsyncStream<SessionUpdate>
    private let updateContinuation: AsyncStream<SessionUpdate>.Continuation
    
    init(
        transport: WebSocketTransport,
        audioEngine: AudioEngine,
        stateManager: SessionStateManager
    ) {
        self.transport = transport
        self.audioEngine = audioEngine
        self.stateManager = stateManager
        
        (self.updateStream, self.updateContinuation) = AsyncStream.makeStream()
        
        Task { await startListening() }
    }
    
    // MARK: Public API
    
    func connect() async throws {
        try await transport.connect()
        sessionID = await transport.sessionID
        transitionTo(.connected)
    }
    
    func startRecording() async {
        guard canStartRecording() else { return }
        
        let turnID = UUID().uuidString
        currentTurnID = turnID
        
        await audioEngine.startCapture { [weak self] audioData in
            await self?.handleCapturedAudio(audioData, turnID: turnID)
        }
        
        transitionTo(.recording(turnID: turnID))
        await sendBadge(.userSpeechStart, turnID: turnID)
    }
    
    func stopRecording() async {
        guard case .recording(let turnID) = state else { return }
        
        await audioEngine.stopCapture()
        transitionTo(.processing(turnID: turnID))
        await sendBadge(.userSpeechEnd, turnID: turnID)
    }
    
    func interrupt() async {
        guard case .playing = state else { return }
        
        await audioEngine.stopPlayback()
        await transport.send(.interrupt(currentTurnID))
        transitionTo(.idle)
    }
    
    // MARK: Private
    
    private func startListening() async {
        for await message in transport.messages {
            await handleMessage(message)
        }
    }
    
    private func handleMessage(_ message: WebSocketMessage) async {
        switch message.type {
        case .aiTextDelta:
            updateContinuation.yield(.textDelta(message.text, turnID: message.turnID))
            
        case .aiAudio:
            await audioEngine.enqueueAudio(message.audioData)
            if case .processing = state {
                transitionTo(.playing(turnID: message.turnID))
            }
            
        case .aiTurnEnd:
            transitionTo(.idle)
            updateContinuation.yield(.turnEnded(message.turnID))
            
        case .error:
            handleError(message.error)
        }
    }
    
    private func transitionTo(_ newState: SessionState) {
        guard stateManager.canTransition(from: state, to: newState) else {
            print("Invalid transition: \(state) -> \(newState)")
            return
        }
        state = newState
        updateContinuation.yield(.stateChanged(newState))
    }
    
    private func canStartRecording() -> Bool {
        state == .idle || state == .connected
    }
}

// MARK: - Session State Machine

/// 会话状态
enum SessionState: Equatable {
    case idle
    case connected
    case recording(turnID: String)
    case processing(turnID: String)
    case playing(turnID: String)
    case error(Error)
    
    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connected, .connected): return true
        case (.recording(let a), .recording(let b)): return a == b
        case (.processing(let a), .processing(let b)): return a == b
        case (.playing(let a), .playing(let b)): return a == b
        default: return false
        }
    }
}

/// 状态转换管理器
struct SessionStateManager {
    /// 合法的状态转换表
    private let transitions: [SessionState: Set<SessionState>] = [
        .idle: [.connected, .recording],
        .connected: [.recording, .error],
        .recording: [.processing, .error],
        .processing: [.playing, .idle, .error],
        .playing: [.idle, .error],
        .error: [.idle]
    ]
    
    func canTransition(from current: SessionState, to next: SessionState) -> Bool {
        // 简化的比较（实际需要考虑关联值）
        transitions[current]?.contains(next) ?? false
    }
}

// MARK: - Session Updates

/// 会话更新事件
enum SessionUpdate {
    case stateChanged(SessionState)
    case textDelta(String, turnID: String)
    case turnEnded(String)
    case error(Error)
}
```

**设计要点**:
- Service 是 `actor`，保证线程安全
- 状态机显式定义，非法转换被拒绝
- 使用 `AsyncStream` 发布事件到 UI
- 依赖通过初始化注入，便于测试

### 2.3 Infrastructure Layer (基础设施层)

**职责**:
- WebSocket 连接管理
- 音频采集与播放
- 协议编解码
- 底层错误处理

**核心组件**:

```swift
// MARK: - WebSocket Transport

/// WebSocket 传输层协议
protocol WebSocketTransport: Actor {
    var sessionID: String? { get async }
    var messages: AsyncStream<WebSocketMessage> { get }
    
    func connect() async throws
    func disconnect() async
    func send(_ message: WebSocketMessage) async throws
}

/// WebSocket 消息
struct WebSocketMessage: Codable {
    let type: MessageType
    let sessionID: String?
    let turnID: String?
    let sequence: Int?
    let data: Data?
    let text: String?
    let timestamp: TimeInterval
    
    enum MessageType: String, Codable {
        case userAudio = "user.audio"
        case userSpeechStart = "user.speech.start"
        case userSpeechEnd = "user.speech.end"
        case aiTextDelta = "ai.text.delta"
        case aiAudio = "ai.audio"
        case aiTTSStart = "ai.tts.start"
        case aiTTSEnd = "ai.tts.end"
        case aiTurnEnd = "ai.turn.end"
        case error = "error"
        case interrupt = "control.interrupt"
    }
}

/// URLSession 实现
actor URLSessionWebSocketTransport: WebSocketTransport {
    private let url: URL
    private var webSocket: URLSessionWebSocketTask?
    private var _sessionID: String?
    
    private let messageStream: AsyncStream<WebSocketMessage>
    private let messageContinuation: AsyncStream<WebSocketMessage>.Continuation
    
    var sessionID: String? { _sessionID }
    var messages: AsyncStream<WebSocketMessage> { messageStream }
    
    init(url: URL) {
        self.url = url
        (self.messageStream, self.messageContinuation) = AsyncStream.makeStream()
    }
    
    func connect() async throws {
        let session = URLSession.shared
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        
        // 等待握手消息获取 session_id
        _sessionID = try await receiveSessionID()
        
        // 开始监听消息
        Task { await receiveMessages() }
    }
    
    func disconnect() async {
        webSocket?.cancel(with: .goingAway, reason: nil)
        messageContinuation.finish()
    }
    
    func send(_ message: WebSocketMessage) async throws {
        let data = try JSONEncoder().encode(message)
        try await webSocket?.send(.data(data))
    }
    
    private func receiveMessages() async {
        while let webSocket = webSocket {
            do {
                let message = try await webSocket.receive()
                if case .data(let data) = message {
                    let decoded = try JSONDecoder().decode(WebSocketMessage.self, from: data)
                    messageContinuation.yield(decoded)
                }
            } catch {
                messageContinuation.finish()
                break
            }
        }
    }
    
    private func receiveSessionID() async throws -> String {
        // 实现握手逻辑
        // ...
        return "session_\(UUID().uuidString)"
    }
}

// MARK: - Audio Engine

/// 音频引擎协议
protocol AudioEngine: Actor {
    func startCapture(onAudioData: @escaping (Data) async -> Void) async throws
    func stopCapture() async
    func enqueueAudio(_ data: Data) async throws
    func stopPlayback() async
}

/// AVAudioEngine 实现
actor AVAudioEngineImpl: AudioEngine {
    private let engine = AVAudioEngine()
    private let audioFormat: AVAudioFormat
    private var captureHandler: ((Data) async -> Void)?
    
    private let playerNode = AVAudioPlayerNode()
    private var audioQueue: [Data] = []
    
    init() {
        // 16kHz, 单声道, 16-bit PCM
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        setupAudioSession()
        setupEngine()
    }
    
    func startCapture(onAudioData: @escaping (Data) async -> Void) async throws {
        self.captureHandler = onAudioData
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            Task {
                guard let self = self else { return }
                let data = await self.convertToData(buffer)
                await self.captureHandler?(data)
            }
        }
        
        try engine.start()
    }
    
    func stopCapture() async {
        engine.inputNode.removeTap(onBus: 0)
        captureHandler = nil
    }
    
    func enqueueAudio(_ data: Data) async throws {
        audioQueue.append(data)
        
        if !playerNode.isPlaying {
            try await playNextInQueue()
        }
    }
    
    func stopPlayback() async {
        playerNode.stop()
        audioQueue.removeAll()
    }
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try? session.setActive(true)
    }
    
    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
        engine.prepare()
    }
    
    private func playNextInQueue() async throws {
        guard !audioQueue.isEmpty else { return }
        let data = audioQueue.removeFirst()
        
        let buffer = try createAudioBuffer(from: data)
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { try? await self?.playNextInQueue() }
        }
        
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
    
    private func convertToData(_ buffer: AVAudioPCMBuffer) async -> Data {
        // 转换 AVAudioPCMBuffer 为 Data
        // ...
        return Data()
    }
    
    private func createAudioBuffer(from data: Data) throws -> AVAudioPCMBuffer {
        // 转换 Data 为 AVAudioPCMBuffer
        // ...
        return AVAudioPCMBuffer()!
    }
}
```

**设计要点**:
- 使用协议抽象，便于替换实现
- Transport 和 Engine 都是 `actor`，保证线程安全
- 使用 `AsyncStream` 处理持续事件流
- 音频处理在独立线程，避免阻塞主线程

---

## 三、数据流

### 3.1 上行流（用户 → 服务端）

```
User presses button
        ↓
ConversationView
        ↓
ConversationViewModel.startRecording()
        ↓
VoiceSessionService.startRecording() [actor]
        ↓
AudioEngine.startCapture() [actor]
        ↓
[Audio callback thread]
AVAudioEngine tap → captured PCM data
        ↓
[Back to actor]
VoiceSessionService.handleCapturedAudio()
        ↓
WebSocketTransport.send(userAudio) [actor]
        ↓
URLSessionWebSocketTask
        ↓
Network → Backend
```

### 3.2 下行流（服务端 → 用户）

```
Network ← Backend
        ↓
URLSessionWebSocketTask receives data
        ↓
URLSessionWebSocketTransport.receiveMessages() [actor]
        ↓
AsyncStream yields WebSocketMessage
        ↓
VoiceSessionService.handleMessage() [actor]
        ↓
        ├─ aiTextDelta → updateContinuation.yield()
        │                       ↓
        │               ConversationViewModel observes
        │                       ↓
        │               @Published property updates
        │                       ↓
        │               SwiftUI View re-renders
        │
        └─ aiAudio → AudioEngine.enqueueAudio() [actor]
                            ↓
                    AVAudioPlayerNode.scheduleBuffer()
                            ↓
                    [Audio render thread]
                    Audio output → Speaker
```

### 3.3 线程模型

```
┌─────────────────────────────────────────────────────────┐
│                     Main Thread                          │
│  - SwiftUI Views rendering                              │
│  - @Published property updates                          │
│  - User interactions                                     │
└─────────────────────────────────────────────────────────┘
                         │
                         │ async/await
                         ▼
┌─────────────────────────────────────────────────────────┐
│               Actor Executor (System Managed)            │
│  - VoiceSessionService (business logic)                 │
│  - WebSocketTransport (network I/O)                     │
│  - AudioEngine (audio coordination)                     │
└─────────────────────────────────────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
┌──────────────┐  ┌────────────┐  ┌───────────────┐
│ Audio Capture│  │  Network   │  │ Audio Playback│
│    Thread    │  │   Thread   │  │    Thread     │
│  (RT Priority)│  │            │  │  (RT Priority)│
└──────────────┘  └────────────┘  └───────────────┘
```

---

## 四、依赖关系

### 4.1 依赖图

```
ConversationView
        │
        └─ ConversationViewModel
                    │
                    └─ VoiceSessionService
                            ├─ WebSocketTransport (protocol)
                            │       └─ URLSessionWebSocketTransport (impl)
                            │
                            ├─ AudioEngine (protocol)
                            │       └─ AVAudioEngineImpl (impl)
                            │
                            └─ SessionStateManager (struct)
```

### 4.2 依赖注入

```swift
// MARK: - Dependency Container

class ServiceContainer {
    // Singletons
    lazy var webSocketTransport: WebSocketTransport = {
        URLSessionWebSocketTransport(url: config.serverURL)
    }()
    
    lazy var audioEngine: AudioEngine = {
        AVAudioEngineImpl()
    }()
    
    // Factories
    func makeVoiceSessionService() -> VoiceSessionService {
        VoiceSessionService(
            transport: webSocketTransport,
            audioEngine: audioEngine,
            stateManager: SessionStateManager()
        )
    }
    
    func makeConversationViewModel() -> ConversationViewModel {
        ConversationViewModel(
            sessionService: makeVoiceSessionService()
        )
    }
}

// MARK: - SwiftUI App

@main
struct VoiceApp: App {
    let container = ServiceContainer()
    
    var body: some Scene {
        WindowGroup {
            ConversationView(
                viewModel: container.makeConversationViewModel()
            )
        }
    }
}
```

---

## 五、错误处理策略

### 5.1 错误分层

```swift
// MARK: - Error Hierarchy

protocol VoiceError: Error {
    var isRecoverable: Bool { get }
    var userMessage: String { get }
}

// 网络层错误
enum NetworkError: VoiceError {
    case connectionFailed
    case timeout
    case serverError(Int)
    
    var isRecoverable: Bool {
        switch self {
        case .connectionFailed, .timeout: return true
        case .serverError(let code): return code >= 500
        }
    }
}

// 音频层错误
enum AudioError: VoiceError {
    case microphonePermissionDenied
    case audioSessionInterrupted
    case bufferOverflow
    
    var isRecoverable: Bool {
        switch self {
        case .microphonePermissionDenied: return false
        case .audioSessionInterrupted, .bufferOverflow: return true
        }
    }
}

// 业务层错误
enum SessionError: VoiceError {
    case invalidState
    case turnTimeout
    case unexpectedMessage
    
    var isRecoverable: Bool { true }
}
```

### 5.2 恢复策略

| 错误类型 | 策略 | 实现 |
|---------|------|------|
| 网络断开 | 自动重连 | 指数退避，最多 5 次 |
| 音频中断 | 暂停会话 | 监听 AVAudioSession 通知 |
| 权限拒绝 | 提示用户 | 跳转系统设置 |
| 服务端错误 | 降级 | 显示文本，不播放音频 |

---

## 六、模块边界

### 6.1 模块划分

```
FluentWorkVoice (Target)
├── Presentation/
│   ├── Views/
│   ├── ViewModels/
│   └── Components/
├── Domain/
│   ├── Services/
│   ├── Models/
│   └── StateMachine/
└── Infrastructure/
    ├── Network/
    ├── Audio/
    └── Protocols/

FluentWorkVoiceCore (Framework - 可复用)
├── AudioEngine/
├── WebSocketTransport/
└── Codecs/

FluentWorkVoiceTests (Test Target)
├── Mocks/
├── UnitTests/
└── IntegrationTests/
```

### 6.2 公开接口

**仅暴露必要接口**:
- `VoiceSessionService` - 业务层入口
- `WebSocketTransport` - 传输层协议
- `AudioEngine` - 音频层协议

**内部实现隐藏**:
- 状态机细节
- 音频缓冲管理
- 网络重试逻辑

---

## 七、总结

### 核心架构特点

1. **三层分离**: Presentation / Domain / Infrastructure
2. **Actor 并发**: 所有状态保护在 actor 内
3. **协议抽象**: 依赖协议而非具体类
4. **事件驱动**: AsyncStream 连接各层
5. **状态机**: 显式状态转换，拒绝非法操作

### 关键设计决策

| 决策 | 理由 | 权衡 |
|------|------|------|
| Actor 而非 DispatchQueue | 编译器保证线程安全 | iOS 15+ only |
| AsyncStream 而非 Combine | 更简洁，与 async/await 集成好 | 生态较新 |
| 协议注入而非单例 | 可测试性 | 稍多样板代码 |
| 状态机而非布尔标志 | 清晰性、可维护性 | 初期开发稍慢 |

下一步: [03_audio_pipeline.md](03_audio_pipeline.md) - 音频采集与播放链路设计
