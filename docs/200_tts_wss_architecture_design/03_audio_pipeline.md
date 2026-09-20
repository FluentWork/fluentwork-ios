# 音频采集与播放链路

**日期**: 2026-09-21  
**目标**: 详细设计音频采集、编码、传输、解码、播放的完整链路

---

## 一、音频参数规格

### 1.1 采样参数

| 参数 | 上行（采集） | 下行（播放） | 理由 |
|------|------------|------------|------|
| 采样率 | 16kHz | 16kHz | 语音识别标准，平衡质量与带宽 |
| 位深度 | 16-bit PCM | 16-bit PCM | CD 质量，iOS 原生支持 |
| 通道数 | 1 (mono) | 1 (mono) | 语音无需立体声 |
| 帧大小 | 20ms (320 samples) | 20ms | 平衡延迟与效率 |
| 缓冲区 | 1024 samples (~64ms) | 可变 | AVAudioEngine 推荐值 |

### 1.2 编码格式

**上行**: PCM → Opus 编码 → Base64 → WebSocket

**下行**: WebSocket → Base64 解码 → Opus 解码 → PCM → 播放

**Opus 参数**:
- 码率: 16 kbps (语音模式)
- 复杂度: 5 (平衡质量与性能)
- 帧大小: 20ms
- 信号类型: `OPUS_SIGNAL_VOICE`

---

## 二、上行链路（采集 → 传输）

### 2.1 架构图

```
┌──────────────────────────────────────────────────────────┐
│                    Microphone                             │
└────────────────────┬─────────────────────────────────────┘
                     │ Analog Audio
                     ▼
┌──────────────────────────────────────────────────────────┐
│              AVAudioEngine.inputNode                      │
│  - 配置 AVAudioSession (.playAndRecord)                   │
│  - installTap (bufferSize: 1024)                         │
└────────────────────┬─────────────────────────────────────┘
                     │ AVAudioPCMBuffer (48kHz by default)
                     ▼
┌──────────────────────────────────────────────────────────┐
│            AudioCaptureProcessor (actor)                  │
│  1. 重采样: 48kHz → 16kHz                                 │
│  2. 格式转换: Float32 → Int16                             │
│  3. 分帧: 1024 samples → 320 samples (20ms)              │
└────────────────────┬─────────────────────────────────────┘
                     │ Data (320 samples * 2 bytes = 640 bytes)
                     ▼
┌──────────────────────────────────────────────────────────┐
│              OpusEncoder (actor)                          │
│  - opus_encode(): PCM → Opus                             │
│  - 640 bytes → ~40 bytes (16kbps)                        │
└────────────────────┬─────────────────────────────────────┘
                     │ Data (Opus encoded)
                     ▼
┌──────────────────────────────────────────────────────────┐
│          WebSocketMessageBuilder (actor)                  │
│  - 添加 metadata (turnID, sequence)                      │
│  - Base64 编码                                           │
│  - 构造 JSON                                             │
└────────────────────┬─────────────────────────────────────┘
                     │ WebSocketMessage
                     ▼
┌──────────────────────────────────────────────────────────┐
│            WebSocketTransport (actor)                     │
│  - 序列化 JSON                                           │
│  - 通过 URLSessionWebSocketTask 发送                     │
└────────────────────┬─────────────────────────────────────┘
                     │ Binary frame
                     ▼
                  Network
```

### 2.2 核心代码实现

```swift
// MARK: - Audio Capture Processor

actor AudioCaptureProcessor {
    private let targetFormat: AVAudioFormat
    private let frameSize: AVAudioFrameCount = 320 // 20ms at 16kHz
    private var buffer: [Int16] = []
    
    private let encoder: OpusEncoder
    private let messageBuilder: WebSocketMessageBuilder
    private let transport: WebSocketTransport
    
    private var currentTurnID: String?
    private var sequenceNumber: Int = 0
    
    init(
        encoder: OpusEncoder,
        messageBuilder: WebSocketMessageBuilder,
        transport: WebSocketTransport
    ) {
        // 16kHz, mono, Int16
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        self.encoder = encoder
        self.messageBuilder = messageBuilder
        self.transport = transport
    }
    
    // 从 AVAudioEngine tap 回调
    func process(_ buffer: AVAudioPCMBuffer, turnID: String) async throws {
        if currentTurnID != turnID {
            currentTurnID = turnID
            sequenceNumber = 0
        }
        
        // 1. 重采样到 16kHz
        let resampled = try resample(buffer, to: targetFormat)
        
        // 2. 转换为 Int16
        let int16Data = convertToInt16(resampled)
        
        // 3. 累积到缓冲区
        self.buffer.append(contentsOf: int16Data)
        
        // 4. 分帧并发送
        while self.buffer.count >= frameSize {
            let frame = Array(self.buffer.prefix(Int(frameSize)))
            self.buffer.removeFirst(Int(frameSize))
            
            try await sendFrame(frame, turnID: turnID)
        }
    }
    
    func flush(turnID: String) async throws {
        // 发送剩余数据（不足一帧时填充静音）
        if !buffer.isEmpty {
            let frame = buffer + Array(repeating: 0, count: Int(frameSize) - buffer.count)
            try await sendFrame(frame, turnID: turnID)
            buffer.removeAll()
        }
    }
    
    private func sendFrame(_ frame: [Int16], turnID: String) async throws {
        // 5. Opus 编码
        let encoded = try await encoder.encode(frame)
        
        // 6. 构造 WebSocket 消息
        let message = await messageBuilder.buildAudioMessage(
            data: encoded,
            turnID: turnID,
            sequence: sequenceNumber
        )
        
        sequenceNumber += 1
        
        // 7. 发送
        try await transport.send(message)
    }
    
    private func resample(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw AudioError.conversionFailed
        }
        
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            throw AudioError.bufferAllocationFailed
        }
        
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        if let error = error {
            throw AudioError.conversionError(error)
        }
        
        return outputBuffer
    }
    
    private func convertToInt16(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let floatData = buffer.floatChannelData?[0] else {
            return []
        }
        
        let frameCount = Int(buffer.frameLength)
        var int16Data: [Int16] = []
        int16Data.reserveCapacity(frameCount)
        
        for i in 0..<frameCount {
            // Float32 [-1.0, 1.0] → Int16 [-32768, 32767]
            let sample = floatData[i]
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = clamped * 32767.0
            int16Data.append(Int16(scaled))
        }
        
        return int16Data
    }
}

// MARK: - Opus Encoder

actor OpusEncoder {
    private var encoder: OpaquePointer?
    
    init() throws {
        var error: Int32 = 0
        encoder = opus_encoder_create(
            16000,  // sample rate
            1,      // channels
            OPUS_APPLICATION_VOIP,  // application
            &error
        )
        
        guard error == OPUS_OK else {
            throw AudioError.opusInitFailed(error)
        }
        
        // 配置编码器
        opus_encoder_ctl(encoder, OPUS_SET_BITRATE(16000))  // 16 kbps
        opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(5))   // 复杂度 5
        opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE))
    }
    
    deinit {
        if let encoder = encoder {
            opus_encoder_destroy(encoder)
        }
    }
    
    func encode(_ pcm: [Int16]) throws -> Data {
        let maxOutputSize = 4000  // Opus 最大帧大小
        var output = [UInt8](repeating: 0, count: maxOutputSize)
        
        let encodedSize = opus_encode(
            encoder,
            pcm,
            Int32(pcm.count),
            &output,
            Int32(maxOutputSize)
        )
        
        guard encodedSize > 0 else {
            throw AudioError.opusEncodeFailed(encodedSize)
        }
        
        return Data(output.prefix(Int(encodedSize)))
    }
}

// MARK: - WebSocket Message Builder

actor WebSocketMessageBuilder {
    private let sessionID: String
    
    init(sessionID: String) {
        self.sessionID = sessionID
    }
    
    func buildAudioMessage(
        data: Data,
        turnID: String,
        sequence: Int
    ) -> WebSocketMessage {
        WebSocketMessage(
            type: .userAudio,
            sessionID: sessionID,
            turnID: turnID,
            sequence: sequence,
            data: data.base64EncodedString(),
            timestamp: Date().timeIntervalSince1970
        )
    }
}
```

### 2.3 性能优化

**无锁设计**:
- AVAudioEngine 回调在实时线程，不能加锁
- 使用 actor 的消息队列天然串行化
- 音频数据通过值类型传递（Data, Array）

**内存管理**:
- 预分配缓冲区，避免频繁分配
- 使用 `reserveCapacity` 减少数组扩容
- 及时释放已发送的数据

**批处理**:
- 累积到 20ms 才编码发送
- 减少网络包数量
- 降低 CPU 唤醒频率

---

## 三、下行链路（接收 → 播放）

### 3.1 架构图

```
                  Network
                     │
                     ▼
┌──────────────────────────────────────────────────────────┐
│            WebSocketTransport (actor)                     │
│  - 接收 WebSocket 消息                                    │
│  - 解析 JSON                                             │
└────────────────────┬─────────────────────────────────────┘
                     │ WebSocketMessage
                     ▼
┌──────────────────────────────────────────────────────────┐
│          AudioPlaybackProcessor (actor)                   │
│  1. Base64 解码                                          │
│  2. 按 sequence 排序                                     │
│  3. 丢弃过期/重复帧                                       │
└────────────────────┬─────────────────────────────────────┘
                     │ Data (Opus encoded)
                     ▼
┌──────────────────────────────────────────────────────────┐
│              OpusDecoder (actor)                          │
│  - opus_decode(): Opus → PCM                             │
│  - ~40 bytes → 640 bytes                                 │
└────────────────────┬─────────────────────────────────────┘
                     │ [Int16] (320 samples)
                     ▼
┌──────────────────────────────────────────────────────────┐
│           AudioBufferConverter (actor)                    │
│  - Int16 → Float32                                       │
│  - 创建 AVAudioPCMBuffer                                 │
└────────────────────┬─────────────────────────────────────┘
                     │ AVAudioPCMBuffer
                     ▼
┌──────────────────────────────────────────────────────────┐
│         AVAudioPlayerNode (Main Mix)                      │
│  - scheduleBuffer()                                      │
│  - 自动播放队列                                          │
└────────────────────┬─────────────────────────────────────┘
                     │ Audio samples
                     ▼
┌──────────────────────────────────────────────────────────┐
│              AVAudioEngine.mainMixerNode                  │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ▼
                  Speaker
```

### 3.2 核心代码实现

```swift
// MARK: - Audio Playback Processor

actor AudioPlaybackProcessor {
    private let decoder: OpusDecoder
    private let playerNode: AVAudioPlayerNode
    private let audioFormat: AVAudioFormat
    
    // 播放队列管理
    private var playbackQueue: [AudioFrame] = []
    private var expectedSequence: Int = 0
    private var isPlaying: Bool = false
    
    struct AudioFrame {
        let sequence: Int
        let data: Data
        let turnID: String
    }
    
    init(decoder: OpusDecoder, playerNode: AVAudioPlayerNode) {
        self.decoder = decoder
        self.playerNode = playerNode
        
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }
    
    func enqueue(_ message: WebSocketMessage) async throws {
        guard message.type == .aiAudio,
              let dataString = message.data,
              let turnID = message.turnID,
              let sequence = message.sequence else {
            return
        }
        
        // 1. Base64 解码
        guard let opusData = Data(base64Encoded: dataString) else {
            throw AudioError.invalidBase64
        }
        
        // 2. 构造帧
        let frame = AudioFrame(
            sequence: sequence,
            data: opusData,
            turnID: turnID
        )
        
        // 3. 插入队列（保持有序）
        insertFrame(frame)
        
        // 4. 尝试播放
        try await playNextIfPossible()
    }
    
    func stop() async {
        playerNode.stop()
        playbackQueue.removeAll()
        expectedSequence = 0
        isPlaying = false
    }
    
    private func insertFrame(_ frame: AudioFrame) {
        // 丢弃过期帧
        guard frame.sequence >= expectedSequence else {
            print("Dropping late frame: \(frame.sequence), expected: \(expectedSequence)")
            return
        }
        
        // 去重
        guard !playbackQueue.contains(where: { $0.sequence == frame.sequence }) else {
            print("Dropping duplicate frame: \(frame.sequence)")
            return
        }
        
        // 插入有序队列
        if let index = playbackQueue.firstIndex(where: { $0.sequence > frame.sequence }) {
            playbackQueue.insert(frame, at: index)
        } else {
            playbackQueue.append(frame)
        }
    }
    
    private func playNextIfPossible() async throws {
        // 只有队头是期望序号才播放
        guard let nextFrame = playbackQueue.first,
              nextFrame.sequence == expectedSequence else {
            // 检查是否丢包过多（超过 5 帧）
            if let first = playbackQueue.first,
               first.sequence > expectedSequence + 5 {
                print("Too many missing frames, skipping to \(first.sequence)")
                expectedSequence = first.sequence
            }
            return
        }
        
        playbackQueue.removeFirst()
        expectedSequence += 1
        
        // 解码并播放
        try await playFrame(nextFrame)
        
        // 继续播放下一帧
        try await playNextIfPossible()
    }
    
    private func playFrame(_ frame: AudioFrame) async throws {
        // 1. Opus 解码
        let pcm = try await decoder.decode(frame.data)
        
        // 2. 转换为 AVAudioPCMBuffer
        let buffer = try createAudioBuffer(from: pcm)
        
        // 3. 调度播放
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task {
                // 播放完成回调，继续下一帧
                try? await self?.playNextIfPossible()
            }
        }
        
        // 4. 启动播放（如果还未开始）
        if !isPlaying {
            playerNode.play()
            isPlaying = true
        }
    }
    
    private func createAudioBuffer(from pcm: [Int16]) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(pcm.count)
        ) else {
            throw AudioError.bufferAllocationFailed
        }
        
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        
        guard let channelData = buffer.int16ChannelData else {
            throw AudioError.invalidChannelData
        }
        
        // 复制 PCM 数据
        pcm.withUnsafeBytes { rawBuffer in
            channelData[0].update(from: rawBuffer.bindMemory(to: Int16.self).baseAddress!, count: pcm.count)
        }
        
        return buffer
    }
}

// MARK: - Opus Decoder

actor OpusDecoder {
    private var decoder: OpaquePointer?
    
    init() throws {
        var error: Int32 = 0
        decoder = opus_decoder_create(
            16000,  // sample rate
            1,      // channels
            &error
        )
        
        guard error == OPUS_OK else {
            throw AudioError.opusInitFailed(error)
        }
    }
    
    deinit {
        if let decoder = decoder {
            opus_decoder_destroy(decoder)
        }
    }
    
    func decode(_ opus: Data) throws -> [Int16] {
        let maxFrameSize = 5760  // 120ms at 48kHz (Opus 最大)
        var output = [Int16](repeating: 0, count: maxFrameSize)
        
        let decodedSamples = opus.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            
            return opus_decode(
                decoder,
                baseAddress,
                Int32(opus.count),
                &output,
                Int32(maxFrameSize),
                0  // decode FEC: 0 = no
            )
        }
        
        guard decodedSamples > 0 else {
            throw AudioError.opusDecodeFailed(decodedSamples)
        }
        
        return Array(output.prefix(Int(decodedSamples)))
    }
}
```

### 3.3 播放队列管理

**顺序保证**:
- 按 `sequence` 排序
- 只播放连续序号的帧
- 缺失帧等待一定时间（最多 5 帧）

**丢包处理**:
```swift
// 场景 1: 收到 [1, 2, 4, 5]，缺失 3
// - 播放 1, 2，等待 3
// - 如果 3 超过 100ms 未到，跳过播放 4, 5
// - 用静音帧填充缺口（可选）

// 场景 2: 收到 [1, 2, 8, 9]，缺失 3-7
// - 播放 1, 2，检测大跳跃
// - 直接跳到 8，避免长时间静音
```

**内存限制**:
- 队列最大长度: 50 帧（1 秒）
- 超过限制丢弃最旧的帧
- 防止内存溢出

---

## 四、音频会话管理

### 4.1 AVAudioSession 配置

```swift
actor AudioSessionManager {
    func configure() throws {
        let session = AVAudioSession.sharedInstance()
        
        // 1. 设置类别
        try session.setCategory(
            .playAndRecord,  // 同时录音和播放
            mode: .voiceChat,  // 优化语音通话
            options: [
                .allowBluetooth,  // 支持蓝牙耳机
                .allowBluetoothA2DP,  // 支持高质量蓝牙
                .defaultToSpeaker  // 默认扬声器（非听筒）
            ]
        )
        
        // 2. 设置采样率偏好
        try session.setPreferredSampleRate(16000)
        
        // 3. 设置 I/O 缓冲区大小
        try session.setPreferredIOBufferDuration(0.02)  // 20ms
        
        // 4. 激活会话
        try session.setActive(true)
    }
    
    func deactivate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
```

### 4.2 中断处理

```swift
actor AudioSessionInterruptionHandler {
    private var onInterruption: ((InterruptionType) -> Void)?
    
    enum InterruptionType {
        case began
        case ended
    }
    
    func startObserving(onInterruption: @escaping (InterruptionType) -> Void) {
        self.onInterruption = onInterruption
        
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            Task { await self?.handleInterruption(notification) }
        }
    }
    
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // 来电、闹钟等打断
            onInterruption?(.began)
            
        case .ended:
            // 中断结束
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    onInterruption?(.ended)
                }
            }
            
        @unknown default:
            break
        }
    }
}
```

### 4.3 路由变化

```swift
actor AudioRouteChangeHandler {
    func startObserving(onChange: @escaping (RouteChange) -> Void) {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            Task { await self.handleRouteChange(notification, onChange: onChange) }
        }
    }
    
    private func handleRouteChange(
        _ notification: Notification,
        onChange: (RouteChange) -> Void
    ) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            // 插入耳机、连接蓝牙
            onChange(.deviceConnected)
            
        case .oldDeviceUnavailable:
            // 拔出耳机、断开蓝牙
            onChange(.deviceDisconnected)
            
        default:
            break
        }
    }
    
    enum RouteChange {
        case deviceConnected
        case deviceDisconnected
    }
}
```

---

## 五、延迟优化

### 5.1 延迟来源

| 来源 | 典型值 | 优化方法 |
|------|--------|---------|
| 音频采集缓冲 | 20-64ms | 减小 bufferSize |
| 重采样 | 1-5ms | 使用硬件采样率 |
| Opus 编码 | 1-3ms | 降低复杂度 |
| 网络传输 | 10-100ms | 减小帧大小、使用 WSS |
| Opus 解码 | 1-3ms | - |
| 播放队列 | 20-60ms | 减小队列深度 |
| **总计** | **53-235ms** | - |

### 5.2 优化策略

**1. 减小音频缓冲区**:
```swift
// 推荐: 1024 samples at 48kHz = 21.3ms
// 激进: 512 samples = 10.6ms (更高 CPU)
engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { ... }
```

**2. 避免重采样**:
```swift
// 如果硬件支持 16kHz，直接使用
let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
if hardwareFormat.sampleRate == 16000 {
    // 跳过重采样步骤
}
```

**3. 播放预加载**:
```swift
// 收到第一帧立即开始播放，不等完整音频
if playbackQueue.count == 1 {
    playerNode.play()  // 立即启动
}
```

**4. 网络优先级**:
```swift
// 使用 .default 或更高优先级
let config = URLSessionConfiguration.default
config.networkServiceType = .voice  // VoIP 优先级
```

---

## 六、音质保证

### 6.1 回声消除

**系统级 AEC**:
```swift
// iOS 自动启用，当使用 .voiceChat mode
try session.setCategory(.playAndRecord, mode: .voiceChat)
```

**验证 AEC 生效**:
- 播放音频时录音，检查是否有回声
- 使用 Audio MIDI Setup.app 查看设备属性

### 6.2 自动增益控制（AGC）

**启用 AGC**:
```swift
// iOS 自动在 .voiceChat 模式下启用
// 无需手动配置
```

**调整增益范围**:
```swift
// 如果需要手动控制
try session.setInputGain(0.8)  // 0.0 - 1.0
```

### 6.3 噪声抑制

**系统级降噪**:
```swift
// iOS 在 .voiceChat 模式自动启用
// 适合语音通话场景
```

**监控音频质量**:
```swift
// 计算信噪比（可选）
func calculateSNR(_ buffer: AVAudioPCMBuffer) -> Double {
    guard let data = buffer.floatChannelData?[0] else { return 0 }
    
    var signal: Float = 0
    var noise: Float = 0
    
    for i in 0..<Int(buffer.frameLength) {
        let sample = data[i]
        signal += sample * sample
        
        // 简化：假设低于阈值的是噪声
        if abs(sample) < 0.01 {
            noise += sample * sample
        }
    }
    
    return 10 * log10(signal / max(noise, 0.0001))
}
```

---

## 七、错误处理

### 7.1 音频错误

```swift
enum AudioError: Error {
    case sessionConfigurationFailed
    case microphonePermissionDenied
    case audioEngineStartFailed
    case bufferAllocationFailed
    case conversionFailed
    case opusInitFailed(Int32)
    case opusEncodeFailed(Int32)
    case opusDecodeFailed(Int32)
}
```

### 7.2 降级策略

| 错误 | 降级方案 | 用户体验 |
|------|---------|---------|
| 麦克风权限拒绝 | 禁用录音，显示设置按钮 | 无法说话 |
| Opus 编码失败 | 发送静音帧 | 服务端收到静音 |
| Opus 解码失败 | 跳过该帧 | 音频有短暂空白 |
| 播放队列溢出 | 丢弃最旧帧 | 可能跳过部分音频 |
| 音频中断 | 暂停会话 | 显示"通话已暂停" |

---

## 八、测试验证

### 8.1 单元测试

```swift
class OpusCodecTests: XCTestCase {
    func testEncodeDecodeRoundTrip() async throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        
        // 生成测试音频（1kHz 正弦波）
        let sampleRate = 16000
        let duration = 0.02  // 20ms
        let frequency = 1000.0
        
        var pcm: [Int16] = []
        for i in 0..<Int(Double(sampleRate) * duration) {
            let t = Double(i) / Double(sampleRate)
            let sample = sin(2.0 * .pi * frequency * t)
            pcm.append(Int16(sample * 32767.0))
        }
        
        // 编码
        let encoded = try await encoder.encode(pcm)
        XCTAssertLessThan(encoded.count, pcm.count * 2)  // 压缩率检查
        
        // 解码
        let decoded = try await decoder.decode(encoded)
        XCTAssertEqual(decoded.count, pcm.count)
        
        // 验证质量（容许小误差）
        let mse = zip(pcm, decoded).reduce(0.0) { sum, pair in
            let diff = Double(pair.0 - pair.1)
            return sum + diff * diff
        } / Double(pcm.count)
        
        XCTAssertLessThan(mse, 100.0)  // 均方误差阈值
    }
}
```

### 8.2 集成测试

```swift
class AudioPipelineTests: XCTestCase {
    func testEndToEndLatency() async throws {
        let pipeline = AudioPipeline()
        
        let startTime = Date()
        
        // 模拟录音 → 编码 → 传输 → 解码 → 播放
        try await pipeline.processTestAudio()
        
        let latency = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(latency, 0.1)  // < 100ms
    }
}
```

### 8.3 真机测试

**Loopback 测试**:
1. 连接设备到 Mac
2. 打开 Audio MIDI Setup
3. 创建 Aggregate Device (iPhone mic + Mac speaker)
4. 录制输出，验证延迟

---

## 总结

### 关键设计点

1. **低延迟优先**: 20ms 帧大小，最小缓冲
2. **Actor 隔离**: 所有音频处理在 actor 内
3. **顺序保证**: 严格按 sequence 播放
4. **错误容忍**: 丢包、延迟、中断都有降级方案
5. **系统集成**: 充分利用 iOS 的 AEC/AGC/降噪

### 性能目标

- 端到端延迟: < 200ms (采集到播放)
- CPU 占用: < 15%
- 内存占用: < 20MB
- 音频质量: 无明显失真

下一步: [04_websocket_protocol.md](04_websocket_protocol.md) - WebSocket 协议设计
