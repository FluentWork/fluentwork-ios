# 实时对话引擎设计

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 3  
**状态**: 设计阶段

---

## 一、设计目标

实时对话引擎是 Practice Room 的核心，负责 WebSocket 全双工通信、流式 ASR/LLM/TTS 处理、以及首响延迟优化。

**关键指标**:
- 首响延迟 P90 ≤ 1.5s
- 转录延迟 ≤ 1s
- 音频质量清晰可懂
- 网络抖动自动恢复

---

## 二、WebSocket 对话协议

### 2.1 协议设计

复用已有的 TTS WebSocket 架构（docs/70_tts_wss_refactor/），在此基础上扩展：

```
Client                           Server
  │                                │
  │─── WebSocket Handshake ──────>│
  │<─── Connected ─────────────────│
  │                                │
  │─── StartSession ──────────────>│
  │    {                           │
  │      sessionID,                │
  │      systemPrompt,             │
  │      enableInstantFeedback     │
  │    }                           │
  │<─── SessionStarted ────────────│
  │                                │
  │─── Audio Chunk (binary) ──────>│
  │─── Audio Chunk ────────────────>│
  │                                │
  │<─── TranscriptUpdate ──────────│
  │    { text, isFinal }           │
  │                                │
  │<─── AIAudioChunk (binary) ─────│
  │<─── AIAudioChunk ──────────────│
  │                                │
  │<─── TurnCompleted ─────────────│
  │    { speaker, transcript }     │
  │                                │
  │─── EndSession ─────────────────>│
  │<─── SessionEnded ──────────────│
  │                                │
```

### 2.2 消息格式

**客户端 → 服务端**:

```swift
enum ClientMessage: Codable {
    case startSession(StartSessionRequest)
    case audioChunk(Data)  // 二进制音频数据
    case endSession
    case injectContext(String)  // 用于即时反馈通知
}

struct StartSessionRequest: Codable {
    let sessionID: String
    let systemPrompt: String
    let userContext: [String: String]
    let enableInstantFeedback: Bool
    let enableStallRescue: Bool
}
```

**服务端 → 客户端**:

```swift
enum ServerMessage: Codable {
    case sessionStarted(SessionStartedResponse)
    case transcriptUpdate(TranscriptUpdate)
    case aiAudioChunk(Data)  // 二进制音频数据
    case aiTextDelta(String)
    case turnCompleted(TurnCompletedEvent)
    case phraseMatched(PhraseMatchEvent)
    case stallDetected(StallDetectedEvent)
    case rescueLadder(RescueLadderEvent)
    case error(ErrorResponse)
    case sessionEnded
}

struct TranscriptUpdate: Codable {
    let text: String
    let isFinal: Bool
    let confidence: Float?
}

struct TurnCompletedEvent: Codable {
    let turnID: String
    let speaker: Speaker
    let transcript: String
    let audioURL: URL?
    let timestamp: Date
}

enum Speaker: String, Codable {
    case user
    case ai
}
```

### 2.3 连接管理

```swift
actor WebSocketTransport {
    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession
    private let endpoint: URL
    
    private let eventContinuation: AsyncStream<ServerMessage>.Continuation
    let events: AsyncStream<ServerMessage>
    
    init(endpoint: URL) {
        self.endpoint = endpoint
        self.session = URLSession(configuration: .default)
        (events, eventContinuation) = AsyncStream.makeStream()
    }
    
    func connect() async throws {
        guard webSocket == nil else {
            throw TransportError.alreadyConnected
        }
        
        let ws = session.webSocketTask(with: endpoint)
        webSocket = ws
        ws.resume()
        
        // 开始接收消息
        Task {
            await receiveMessages()
        }
        
        // 等待连接确认
        try await waitForConnection()
    }
    
    func disconnect() async {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }
    
    func send(_ message: ClientMessage) async throws {
        guard let ws = webSocket else {
            throw TransportError.notConnected
        }
        
        let data: Data
        switch message {
        case .audioChunk(let audioData):
            data = audioData
        default:
            data = try JSONEncoder().encode(message)
        }
        
        let wsMessage = URLSessionWebSocketTask.Message.data(data)
        try await ws.send(wsMessage)
    }
    
    private func receiveMessages() async {
        while let ws = webSocket {
            do {
                let message = try await ws.receive()
                await handleMessage(message)
            } catch {
                eventContinuation.yield(.error(ErrorResponse(message: error.localizedDescription)))
                break
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .data(let data):
            // 尝试解析为 JSON
            if let serverMessage = try? JSONDecoder().decode(ServerMessage.self, from: data) {
                eventContinuation.yield(serverMessage)
            } else {
                // 二进制音频数据
                eventContinuation.yield(.aiAudioChunk(data))
            }
            
        case .string(let text):
            if let data = text.data(using: .utf8),
               let serverMessage = try? JSONDecoder().decode(ServerMessage.self, from: data) {
                eventContinuation.yield(serverMessage)
            }
            
        @unknown default:
            break
        }
    }
    
    private func waitForConnection() async throws {
        // 等待 sessionStarted 消息或超时
        for await event in events {
            if case .sessionStarted = event {
                return
            }
            if case .error = event {
                throw TransportError.connectionFailed
            }
        }
    }
}

enum TransportError: Error {
    case alreadyConnected
    case notConnected
    case connectionFailed
    case timeout
}
```

---

## 三、流式处理链路

### 3.1 音频采集与编码

```swift
actor AudioCaptureEngine {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    
    private let audioContinuation: AsyncStream<Data>.Continuation
    let audioStream: AsyncStream<Data>
    
    init() {
        (audioStream, audioContinuation) = AsyncStream.makeStream()
    }
    
    func startCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // 配置音频格式：16kHz, 单声道, PCM
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        // 安装音频 tap
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, time in
            guard let self = self else { return }
            
            // 转换格式
            if let convertedBuffer = self.convert(buffer, to: recordingFormat) {
                let data = self.bufferToData(convertedBuffer)
                Task {
                    await self.audioContinuation.yield(data)
                }
            }
        }
        
        try engine.start()
        self.audioEngine = engine
        self.inputNode = inputNode
    }
    
    func stopCapture() {
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
    }
    
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }
        
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate
        )
        
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            return nil
        }
        
        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        return error == nil ? convertedBuffer : nil
    }
    
    private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        let data = Data(
            bytes: audioBuffer.mData!,
            count: Int(audioBuffer.mDataByteSize)
        )
        return data
    }
}
```

### 3.2 音频播放引擎

```swift
actor AudioPlaybackEngine {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    
    private var audioQueue: [AVAudioPCMBuffer] = []
    private var isPlaying = false
    
    func startPlayback() throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        engine.attach(playerNode)
        engine.connect(
            playerNode,
            to: engine.mainMixerNode,
            format: nil
        )
        
        try engine.start()
        playerNode.play()
        
        self.audioEngine = engine
        self.playerNode = playerNode
        self.isPlaying = true
    }
    
    func stopPlayback() {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        isPlaying = false
        audioQueue.removeAll()
    }
    
    func enqueueAudio(_ data: Data) {
        guard let buffer = dataToBuffer(data) else { return }
        audioQueue.append(buffer)
        
        if isPlaying {
            scheduleNextBuffer()
        }
    }
    
    private func scheduleNextBuffer() {
        guard let playerNode = playerNode,
              !audioQueue.isEmpty else {
            return
        }
        
        let buffer = audioQueue.removeFirst()
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task {
                await self?.scheduleNextBuffer()
            }
        }
    }
    
    private func dataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        let frameCount = AVAudioFrameCount(data.count / 2)  // 16-bit = 2 bytes
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            guard let dest = buffer.int16ChannelData?[0] else { return }
            memcpy(dest, source, data.count)
        }
        
        return buffer
    }
}
```

### 3.3 DialogueController - 对话流控制

```swift
actor DialogueController {
    private var turns: [Turn] = []
    private var currentUserUtterance: PartialUtterance?
    private var currentAIUtterance: PartialUtterance?
    
    private let turnContinuation: AsyncStream<Turn>.Continuation
    let turnStream: AsyncStream<Turn>
    
    init() {
        (turnStream, turnContinuation) = AsyncStream.makeStream()
    }
    
    // MARK: - 转录更新
    
    func updateUserTranscript(text: String, isFinal: Bool, confidence: Float?) {
        if currentUserUtterance == nil {
            currentUserUtterance = PartialUtterance(
                id: UUID(),
                speaker: .user,
                startTime: Date()
            )
        }
        
        currentUserUtterance?.transcript = text
        
        if isFinal {
            completeUserUtterance(confidence: confidence)
        }
    }
    
    func updateAITranscript(text: String, isFinal: Bool) {
        if currentAIUtterance == nil {
            currentAIUtterance = PartialUtterance(
                id: UUID(),
                speaker: .ai,
                startTime: Date()
            )
        }
        
        currentAIUtterance?.transcript.append(text)
        
        if isFinal {
            completeAIUtterance()
        }
    }
    
    // MARK: - 话轮完成
    
    private func completeUserUtterance(confidence: Float?) {
        guard let partial = currentUserUtterance else { return }
        
        let turn = Turn(
            id: partial.id,
            speaker: .user,
            audioURL: nil,  // TODO: 保存录音文件
            transcript: partial.transcript,
            timestamp: partial.startTime,
            asrConfidence: confidence,
            matchedPhraseBlocks: [],
            pronunciationScore: nil,
            duration: Date().timeIntervalSince(partial.startTime)
        )
        
        turns.append(turn)
        turnContinuation.yield(turn)
        currentUserUtterance = nil
    }
    
    private func completeAIUtterance() {
        guard let partial = currentAIUtterance else { return }
        
        let turn = Turn(
            id: partial.id,
            speaker: .ai,
            audioURL: nil,
            transcript: partial.transcript,
            timestamp: partial.startTime,
            asrConfidence: nil,
            matchedPhraseBlocks: [],
            pronunciationScore: nil,
            duration: Date().timeIntervalSince(partial.startTime)
        )
        
        turns.append(turn)
        turnContinuation.yield(turn)
        currentAIUtterance = nil
    }
    
    // MARK: - 话术块匹配记录
    
    func recordPhraseBlockMatch(turnID: UUID, phraseBlockID: UUID) {
        if let index = turns.firstIndex(where: { $0.id == turnID }) {
            turns[index].matchedPhraseBlocks.append(phraseBlockID)
        }
    }
    
    // MARK: - 查询
    
    func getAllTurns() -> [Turn] {
        turns
    }
    
    func getUserTurns() -> [Turn] {
        turns.filter { $0.speaker == .user }
    }
    
    func getAITurns() -> [Turn] {
        turns.filter { $0.speaker == .ai }
    }
    
    func getRecentTurns(count: Int) -> [Turn] {
        Array(turns.suffix(count))
    }
}

struct PartialUtterance {
    let id: UUID
    let speaker: Speaker
    let startTime: Date
    var transcript: String = ""
}
```

---

## 四、首响延迟优化

### 4.1 延迟预算分解

目标：首响 P90 ≤ 1.5s

```
用户说话结束
  ↓ ≤200ms    VAD 检测 + 音频缓冲
ASR 识别完成
  ↓ ≤800ms    LLM 处理 + 首 token 生成
LLM 首 token
  ↓ ≤300ms    TTS 合成首音频块
TTS 首音频块
  ↓ ≤200ms    网络传输 + 音频播放启动
音频播放开始
= 1.5s (P90)
```

### 4.2 优化策略

**策略 1: 预连接**

```swift
actor SessionPreparationService {
    private let transport: WebSocketTransport
    
    func prepareForSession() async {
        // 在用户点击"开始"前就建立 WebSocket 连接
        try? await transport.connect()
    }
}
```

**策略 2: 流式处理**

- ASR 实时流式识别，不等待完整句子
- LLM 流式生成，首 token 立即返回
- TTS 流式合成，首音频块立即播放

**策略 3: 并行优化**

```swift
// 即时反馈检测并行于 TTS，不阻塞主流
Task.detached(priority: .userInitiated) {
    await feedbackDetector.detectMatches(userText)
}
```

**策略 4: 降级方案**

```swift
actor LatencyMonitor {
    private var recentLatencies: [TimeInterval] = []
    
    func recordLatency(_ latency: TimeInterval) {
        recentLatencies.append(latency)
        if recentLatencies.count > 100 {
            recentLatencies.removeFirst()
        }
        
        let p90 = calculateP90()
        if p90 > 1.5 {
            // 触发降级
            await enableDegradedMode()
        }
    }
    
    private func calculateP90() -> TimeInterval {
        let sorted = recentLatencies.sorted()
        let index = Int(Double(sorted.count) * 0.9)
        return sorted[index]
    }
    
    private func enableDegradedMode() async {
        // 降级策略：
        // 1. 关闭即时反馈
        // 2. 降低 TTS 质量
        // 3. 使用更快的 LLM 模型
    }
}
```

### 4.3 监控与埋点

```swift
struct LatencyMetrics {
    var vadDetectionTime: TimeInterval
    var asrRecognitionTime: TimeInterval
    var llmFirstTokenTime: TimeInterval
    var ttsFirstChunkTime: TimeInterval
    var networkTransferTime: TimeInterval
    var totalLatency: TimeInterval
    
    var isWithinTarget: Bool {
        totalLatency <= 1.5
    }
}

actor MetricsCollector {
    private var metrics: [LatencyMetrics] = []
    
    func recordMetrics(_ metrics: LatencyMetrics) {
        self.metrics.append(metrics)
        
        // 上报到后端
        Task {
            await reportToBackend(metrics)
        }
        
        // 本地聚合分析
        if self.metrics.count >= 100 {
            analyzeAndOptimize()
        }
    }
    
    private func analyzeAndOptimize() {
        let p50 = calculatePercentile(0.5)
        let p90 = calculatePercentile(0.9)
        let p99 = calculatePercentile(0.99)
        
        Logger.info("Latency P50: \(p50)s, P90: \(p90)s, P99: \(p99)s")
        
        // 识别瓶颈
        let bottleneck = identifyBottleneck()
        Logger.info("Bottleneck: \(bottleneck)")
    }
    
    private func calculatePercentile(_ percentile: Double) -> TimeInterval {
        let sorted = metrics.map(\.totalLatency).sorted()
        let index = Int(Double(sorted.count) * percentile)
        return sorted[index]
    }
    
    private func identifyBottleneck() -> String {
        let avgVAD = metrics.map(\.vadDetectionTime).reduce(0, +) / Double(metrics.count)
        let avgASR = metrics.map(\.asrRecognitionTime).reduce(0, +) / Double(metrics.count)
        let avgLLM = metrics.map(\.llmFirstTokenTime).reduce(0, +) / Double(metrics.count)
        let avgTTS = metrics.map(\.ttsFirstChunkTime).reduce(0, +) / Double(metrics.count)
        
        let stages = [
            ("VAD", avgVAD),
            ("ASR", avgASR),
            ("LLM", avgLLM),
            ("TTS", avgTTS)
        ]
        
        return stages.max(by: { $0.1 < $1.1 })?.0 ?? "Unknown"
    }
    
    private func reportToBackend(_ metrics: LatencyMetrics) async {
        // TODO: 上报到监控系统
    }
}
```

---

## 五、错误恢复机制

### 5.1 网络抖动处理

```swift
actor ReconnectionManager {
    private let transport: WebSocketTransport
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    
    func handleDisconnection() async {
        while reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            
            let backoff = exponentialBackoff(attempt: reconnectAttempts)
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            
            do {
                try await transport.connect()
                reconnectAttempts = 0
                return
            } catch {
                Logger.warning("Reconnection attempt \(reconnectAttempts) failed")
            }
        }
        
        // 重连失败，通知用户
        await notifyReconnectionFailed()
    }
    
    private func exponentialBackoff(attempt: Int) -> TimeInterval {
        min(pow(2.0, Double(attempt)), 30.0)  // 最大 30 秒
    }
    
    private func notifyReconnectionFailed() async {
        // 通知 ViewModel，显示错误提示
    }
}
```

### 5.2 音频会话中断处理

```swift
actor AudioSessionManager {
    func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        
        try session.setActive(true)
        
        // 监听中断事件
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleInterruption(notification)
            }
        }
    }
    
    private func handleInterruption(_ notification: Notification) async {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // 中断开始（来电、闹钟等）
            await pauseSession()
            
        case .ended:
            // 中断结束
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    await resumeSession()
                }
            }
            
        @unknown default:
            break
        }
    }
    
    private func pauseSession() async {
        // 暂停对话
    }
    
    private func resumeSession() async {
        // 恢复对话
    }
}
```

---

## 六、测试策略

### 6.1 单元测试

```swift
@Test
func testWebSocketConnection() async throws {
    let transport = WebSocketTransport(endpoint: URL(string: "wss://test.com")!)
    
    try await transport.connect()
    
    // 验证连接成功
    var receivedSessionStarted = false
    for await event in transport.events {
        if case .sessionStarted = event {
            receivedSessionStarted = true
            break
        }
    }
    
    #expect(receivedSessionStarted)
}

@Test
func testAudioCapture() async throws {
    let engine = AudioCaptureEngine()
    
    try await engine.startCapture()
    
    var capturedAudio: Data?
    for await audioData in engine.audioStream {
        capturedAudio = audioData
        break
    }
    
    #expect(capturedAudio != nil)
    #expect(capturedAudio!.count > 0)
    
    await engine.stopCapture()
}
```

### 6.2 集成测试

```swift
@Test
func testEndToEndDialogue() async throws {
    let service = VoiceSessionService(/* ... */)
    
    // 启动会话
    try await service.startSession(config: testConfig)
    
    // 模拟用户说话
    let audioData = loadTestAudioFile()
    try await service.sendAudio(audioData)
    
    // 等待 AI 响应
    var receivedAIResponse = false
    for await event in service.events {
        if case .aiAudioChunk = event {
            receivedAIResponse = true
            break
        }
    }
    
    #expect(receivedAIResponse)
    
    try await service.endSession()
}
```

### 6.3 性能测试

```swift
@Test
func testFirstResponseLatency() async throws {
    let service = VoiceSessionService(/* ... */)
    let metrics = LatencyMetrics()
    
    let startTime = Date()
    
    try await service.startSession(config: testConfig)
    
    let audioData = loadTestAudioFile()
    try await service.sendAudio(audioData)
    
    // 等待首个 AI 音频块
    for await event in service.events {
        if case .aiAudioChunk = event {
            let latency = Date().timeIntervalSince(startTime)
            #expect(latency <= 1.5, "First response latency \(latency)s exceeds target")
            break
        }
    }
}
```

---

## 七、下一步

本文档完成了实时对话引擎的设计。后续文档将深入其他核心系统：

- [04_instant_feedback_system.md](04_instant_feedback_system.md): 即时反馈系统
- [05_stall_rescue_mechanism.md](05_stall_rescue_mechanism.md): 卡壳救援机制
- [06_material_driven_engine.md](06_material_driven_engine.md): 素材驱动引擎

---

**最后更新**: 2026-09-21  
**下一文档**: [04_instant_feedback_system.md](04_instant_feedback_system.md)
