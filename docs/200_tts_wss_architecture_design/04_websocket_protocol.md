# WebSocket 协议设计

**日期**: 2026-09-21  
**目标**: 定义 iOS 与 Backend 之间的 WebSocket 消息格式与交互协议

---

## 一、协议概述

### 1.1 传输层

- **协议**: WebSocket over TLS (wss://)
- **格式**: JSON 文本消息
- **编码**: UTF-8
- **音频数据**: Base64 编码

### 1.2 连接生命周期

```
Client                          Server
  │                               │
  │──── Connect wss://...  ────→ │
  │←─── 101 Switching Protocols ─│
  │                               │
  │──── session.start ─────────→ │
  │←─── session.ready ───────────│
  │                               │
  │──── user.audio ─────────────→│
  │      (持续发送音频帧)          │
  │──── turn.end ───────────────→│
  │                               │
  │←─── ai.text.delta ───────────│
  │←─── ai.audio ────────────────│
  │      (持续接收音频帧)          │
  │←─── ai.turn.end ─────────────│
  │                               │
  │──── session.end ────────────→│
  │──── Close ──────────────────→│
  │←─── Close ───────────────────│
```

---

## 二、消息格式

### 2.1 基础消息结构

所有消息遵循统一的 JSON 结构：

```json
{
  "type": "message_type",
  "session_id": "uuid-v4",
  "turn_id": "uuid-v4",
  "sequence": 123,
  "timestamp": 1695123456.789,
  "data": { ... }
}
```

**字段说明**:

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| type | string | ✅ | 消息类型 |
| session_id | string | ✅ | 会话唯一标识 |
| turn_id | string | ⚠️ | 对话轮次标识（某些消息可选） |
| sequence | int | ⚠️ | 序列号（音频帧必填） |
| timestamp | float64 | ✅ | Unix 时间戳（秒，带毫秒） |
| data | object/string | ⚠️ | 消息载荷 |

### 2.2 Swift 数据模型

```swift
// MARK: - Base Message

struct WebSocketMessage: Codable {
    let type: MessageType
    let sessionID: String
    let turnID: String?
    let sequence: Int?
    let timestamp: Double
    let data: MessageData?
    
    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case turnID = "turn_id"
        case sequence
        case timestamp
        case data
    }
}

// MARK: - Message Types

enum MessageType: String, Codable {
    // Client → Server
    case sessionStart = "session.start"
    case userAudio = "user.audio"
    case turnEnd = "turn.end"
    case sessionEnd = "session.end"
    case heartbeat = "heartbeat"
    
    // Server → Client
    case sessionReady = "session.ready"
    case aiTextDelta = "ai.text.delta"
    case aiAudio = "ai.audio"
    case aiTurnEnd = "ai.turn.end"
    case error = "error"
    case pong = "pong"
}

// MARK: - Message Data

enum MessageData: Codable {
    case sessionStart(SessionStartData)
    case sessionReady(SessionReadyData)
    case userAudio(String)  // Base64
    case aiAudio(String)    // Base64
    case textDelta(TextDeltaData)
    case turnEnd(TurnEndData)
    case error(ErrorData)
    case empty
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let text = try? container.decode(String.self) {
            // 音频数据是纯字符串
            if text.isEmpty {
                self = .empty
            } else {
                self = .userAudio(text)  // 或 aiAudio，根据 type 判断
            }
        } else if let sessionStart = try? container.decode(SessionStartData.self) {
            self = .sessionStart(sessionStart)
        } else if let sessionReady = try? container.decode(SessionReadyData.self) {
            self = .sessionReady(sessionReady)
        } else if let textDelta = try? container.decode(TextDeltaData.self) {
            self = .textDelta(textDelta)
        } else if let turnEnd = try? container.decode(TurnEndData.self) {
            self = .turnEnd(turnEnd)
        } else if let error = try? container.decode(ErrorData.self) {
            self = .error(error)
        } else {
            self = .empty
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .sessionStart(let data):
            try container.encode(data)
        case .sessionReady(let data):
            try container.encode(data)
        case .userAudio(let base64), .aiAudio(let base64):
            try container.encode(base64)
        case .textDelta(let data):
            try container.encode(data)
        case .turnEnd(let data):
            try container.encode(data)
        case .error(let data):
            try container.encode(data)
        case .empty:
            try container.encodeNil()
        }
    }
}
```

---

## 三、上行消息（Client → Server）

### 3.1 会话启动 (session.start)

**时机**: 建立 WebSocket 连接后首条消息

```json
{
  "type": "session.start",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": 1695123456.789,
  "data": {
    "user_id": "user_123",
    "device_info": {
      "platform": "iOS",
      "version": "17.0",
      "model": "iPhone 15 Pro",
      "app_version": "1.0.0"
    },
    "audio_config": {
      "sample_rate": 16000,
      "channels": 1,
      "codec": "opus",
      "bitrate": 16000
    }
  }
}
```

**Swift 模型**:

```swift
struct SessionStartData: Codable {
    let userID: String
    let deviceInfo: DeviceInfo
    let audioConfig: AudioConfig
    
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceInfo = "device_info"
        case audioConfig = "audio_config"
    }
}

struct DeviceInfo: Codable {
    let platform: String
    let version: String
    let model: String
    let appVersion: String
    
    enum CodingKeys: String, CodingKey {
        case platform, version, model
        case appVersion = "app_version"
    }
}

struct AudioConfig: Codable {
    let sampleRate: Int
    let channels: Int
    let codec: String
    let bitrate: Int
    
    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels, codec, bitrate
    }
}
```

### 3.2 用户音频 (user.audio)

**时机**: 用户说话时，每 20ms 发送一帧

```json
{
  "type": "user.audio",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "turn_id": "turn_001",
  "sequence": 0,
  "timestamp": 1695123456.809,
  "data": "SGVsbG8gV29ybGQ="
}
```

**关键字段**:
- `turn_id`: 本轮对话的唯一标识
- `sequence`: 从 0 开始递增，用于排序和丢包检测
- `data`: Base64 编码的 Opus 音频数据（约 40 字节）

### 3.3 对话结束 (turn.end)

**时机**: 用户松开录音按钮

```json
{
  "type": "turn.end",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "turn_id": "turn_001",
  "timestamp": 1695123458.123,
  "data": {
    "reason": "user_release",
    "audio_duration_ms": 2500,
    "frame_count": 125
  }
}
```

**Swift 模型**:

```swift
struct TurnEndData: Codable {
    let reason: String
    let audioDurationMs: Int
    let frameCount: Int
    
    enum CodingKeys: String, CodingKey {
        case reason
        case audioDurationMs = "audio_duration_ms"
        case frameCount = "frame_count"
    }
}
```

### 3.4 会话结束 (session.end)

**时机**: 用户退出对话界面

```json
{
  "type": "session.end",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": 1695123460.000,
  "data": {
    "reason": "user_exit"
  }
}
```

### 3.5 心跳 (heartbeat)

**时机**: 每 30 秒发送一次（保持连接）

```json
{
  "type": "heartbeat",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": 1695123480.000
}
```

---

## 四、下行消息（Server → Client）

### 4.1 会话就绪 (session.ready)

**时机**: 收到 session.start 后返回

```json
{
  "type": "session.ready",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": 1695123456.800,
  "data": {
    "status": "ready",
    "capabilities": ["streaming_tts", "interruption"]
  }
}
```

**Swift 模型**:

```swift
struct SessionReadyData: Codable {
    let status: String
    let capabilities: [String]
}
```

### 4.2 AI 文本增量 (ai.text.delta)

**时机**: LLM 生成文本时流式返回

```json
{
  "type": "ai.text.delta",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "turn_id": "turn_001",
  "sequence": 0,
  "timestamp": 1695123458.500,
  "data": {
    "text": "你好",
    "is_final": false
  }
}
```

**Swift 模型**:

```swift
struct TextDeltaData: Codable {
    let text: String
    let isFinal: Bool
    
    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}
```

### 4.3 AI 音频 (ai.audio)

**时机**: TTS 合成音频后流式返回

```json
{
  "type": "ai.audio",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "turn_id": "turn_001",
  "sequence": 0,
  "timestamp": 1695123458.600,
  "data": "T3B1cyBhdWRpbyBkYXRhIGhlcmU="
}
```

### 4.4 AI 对话结束 (ai.turn.end)

**时机**: AI 回复完毕

```json
{
  "type": "ai.turn.end",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "turn_id": "turn_001",
  "timestamp": 1695123460.000,
  "data": {
    "text": "你好，有什么可以帮你的吗？",
    "audio_duration_ms": 1500,
    "frame_count": 75
  }
}
```

### 4.5 错误消息 (error)

**时机**: 发生错误时

```json
{
  "type": "error",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": 1695123459.000,
  "data": {
    "code": "ASR_FAILED",
    "message": "语音识别失败",
    "recoverable": true
  }
}
```

**Swift 模型**:

```swift
struct ErrorData: Codable {
    let code: String
    let message: String
    let recoverable: Bool
}
```

---

## 五、序列号管理

### 5.1 序列号规则

**上行（Client → Server）**:
- 每个 `turn_id` 内独立计数
- 从 0 开始，每帧递增 1
- 新 turn 重新从 0 开始

**下行（Server → Client）**:
- 每个 `turn_id` 内独立计数
- 从 0 开始，每帧递增 1
- 客户端必须按序播放

### 5.2 序列号管理器

```swift
actor SequenceNumberManager {
    private var sequences: [String: Int] = [:]  // turnID → sequence
    
    func next(for turnID: String) -> Int {
        let current = sequences[turnID, default: -1]
        let next = current + 1
        sequences[turnID] = next
        return next
    }
    
    func reset(for turnID: String) {
        sequences[turnID] = nil
    }
    
    func resetAll() {
        sequences.removeAll()
    }
}
```

### 5.3 乱序检测

```swift
actor SequenceValidator {
    private var expected: [String: Int] = [:]  // turnID → expected sequence
    
    enum ValidationResult {
        case valid
        case duplicate(received: Int, expected: Int)
        case outOfOrder(received: Int, expected: Int)
        case gapDetected(missing: [Int])
    }
    
    func validate(turnID: String, sequence: Int) -> ValidationResult {
        let expectedSeq = expected[turnID, default: 0]
        
        if sequence == expectedSeq {
            expected[turnID] = sequence + 1
            return .valid
        } else if sequence < expectedSeq {
            return .duplicate(received: sequence, expected: expectedSeq)
        } else if sequence == expectedSeq + 1 {
            expected[turnID] = sequence + 1
            return .valid
        } else {
            let missing = (expectedSeq..<sequence).map { $0 }
            expected[turnID] = sequence + 1
            return .gapDetected(missing: missing)
        }
    }
    
    func reset(for turnID: String) {
        expected[turnID] = nil
    }
}
```

---

## 六、心跳与保活

### 6.1 心跳机制

**客户端职责**:
- 每 30 秒发送 `heartbeat` 消息
- 收到 `pong` 确认连接正常
- 超过 60 秒无 `pong` 视为连接断开

**服务端职责**:
- 收到 `heartbeat` 回复 `pong`
- 超过 90 秒无消息主动关闭连接

### 6.2 心跳管理器

```swift
actor HeartbeatManager {
    private var timer: Task<Void, Never>?
    private var lastPongTime: Date?
    private let interval: TimeInterval = 30.0
    private let timeout: TimeInterval = 60.0
    
    private weak var transport: WebSocketTransport?
    private let onTimeout: () async -> Void
    
    init(transport: WebSocketTransport, onTimeout: @escaping () async -> Void) {
        self.transport = transport
        self.onTimeout = onTimeout
    }
    
    func start() {
        timer?.cancel()
        lastPongTime = Date()
        
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                
                guard let transport = transport else { break }
                
                // 检查超时
                if let lastPong = lastPongTime,
                   Date().timeIntervalSince(lastPong) > timeout {
                    await onTimeout()
                    break
                }
                
                // 发送心跳
                let message = WebSocketMessage(
                    type: .heartbeat,
                    sessionID: await transport.sessionID,
                    turnID: nil,
                    sequence: nil,
                    timestamp: Date().timeIntervalSince1970,
                    data: nil
                )
                
                try? await transport.send(message)
            }
        }
    }
    
    func receivedPong() {
        lastPongTime = Date()
    }
    
    func stop() {
        timer?.cancel()
        timer = nil
    }
}
```

---

## 七、错误码定义

### 7.1 错误码分类

| 类别 | 范围 | 说明 |
|------|------|------|
| 客户端错误 | 4000-4999 | 客户端请求错误 |
| 服务端错误 | 5000-5999 | 服务端内部错误 |
| 业务错误 | 6000-6999 | 业务逻辑错误 |

### 7.2 常见错误码

| 错误码 | 名称 | 说明 | 可恢复 |
|--------|------|------|--------|
| 4001 | INVALID_MESSAGE | 消息格式错误 | ❌ |
| 4002 | INVALID_SESSION | 无效的会话 ID | ❌ |
| 4003 | SESSION_EXPIRED | 会话已过期 | ✅ |
| 4004 | RATE_LIMIT | 请求过于频繁 | ✅ |
| 5001 | INTERNAL_ERROR | 服务器内部错误 | ✅ |
| 5002 | SERVICE_UNAVAILABLE | 服务暂时不可用 | ✅ |
| 6001 | ASR_FAILED | 语音识别失败 | ✅ |
| 6002 | LLM_FAILED | 大模型调用失败 | ✅ |
| 6003 | TTS_FAILED | 语音合成失败 | ✅ |

### 7.3 错误处理

```swift
actor ErrorHandler {
    enum ErrorAction {
        case retry
        case reconnect
        case failSilently
        case showAlert(String)
        case fatal
    }
    
    func handle(_ error: ErrorData) -> ErrorAction {
        switch error.code {
        case "INVALID_MESSAGE", "INVALID_SESSION":
            return .fatal
            
        case "SESSION_EXPIRED":
            return .reconnect
            
        case "RATE_LIMIT":
            return .failSilently
            
        case "ASR_FAILED", "LLM_FAILED", "TTS_FAILED":
            return error.recoverable ? .retry : .showAlert(error.message)
            
        case "INTERNAL_ERROR", "SERVICE_UNAVAILABLE":
            return .retry
            
        default:
            return .showAlert(error.message)
        }
    }
}
```

---

## 八、协议版本管理

### 8.1 版本协商

在 `session.start` 中携带协议版本：

```json
{
  "type": "session.start",
  "session_id": "...",
  "data": {
    "protocol_version": "v1",
    ...
  }
}
```

服务端在 `session.ready` 中确认版本：

```json
{
  "type": "session.ready",
  "session_id": "...",
  "data": {
    "protocol_version": "v1",
    ...
  }
}
```

### 8.2 版本兼容性

**v1 (当前版本)**:
- ✅ 支持 Opus 音频编码
- ✅ 支持流式文本返回
- ✅ 支持流式音频返回
- ✅ 支持中断机制

**v2 (计划)**:
- 支持多轮对话上下文
- 支持音频指纹匹配
- 支持语音克隆

### 8.3 协议冻结测试

```swift
class ProtocolVersionTests: XCTestCase {
    func testV1SchemaIsFrozen() {
        // 确保 v1 协议字段不变
        let json = """
        {
            "type": "session.start",
            "session_id": "test",
            "timestamp": 123.456
        }
        """
        
        let data = json.data(using: .utf8)!
        let message = try! JSONDecoder().decode(WebSocketMessage.self, from: data)
        
        XCTAssertEqual(message.type, .sessionStart)
        XCTAssertEqual(message.sessionID, "test")
        XCTAssertEqual(message.timestamp, 123.456)
    }
}
```

---

## 九、实现示例

### 9.1 消息发送

```swift
actor WebSocketMessageSender {
    private let transport: WebSocketTransport
    private let sessionID: String
    private let sequenceManager: SequenceNumberManager
    
    init(
        transport: WebSocketTransport,
        sessionID: String,
        sequenceManager: SequenceNumberManager
    ) {
        self.transport = transport
        self.sessionID = sessionID
        self.sequenceManager = sequenceManager
    }
    
    func sendAudio(_ audioData: Data, turnID: String) async throws {
        let sequence = await sequenceManager.next(for: turnID)
        
        let message = WebSocketMessage(
            type: .userAudio,
            sessionID: sessionID,
            turnID: turnID,
            sequence: sequence,
            timestamp: Date().timeIntervalSince1970,
            data: .userAudio(audioData.base64EncodedString())
        )
        
        try await transport.send(message)
    }
    
    func sendTurnEnd(_ turnID: String, duration: Int, frameCount: Int) async throws {
        let message = WebSocketMessage(
            type: .turnEnd,
            sessionID: sessionID,
            turnID: turnID,
            sequence: nil,
            timestamp: Date().timeIntervalSince1970,
            data: .turnEnd(TurnEndData(
                reason: "user_release",
                audioDurationMs: duration,
                frameCount: frameCount
            ))
        )
        
        try await transport.send(message)
    }
}
```

### 9.2 消息接收

```swift
actor WebSocketMessageReceiver {
    private let validator: SequenceValidator
    private let errorHandler: ErrorHandler
    
    private let onTextDelta: (String) async -> Void
    private let onAudioFrame: (Data, Int) async -> Void
    private let onTurnEnd: (String) async -> Void
    
    init(
        validator: SequenceValidator,
        errorHandler: ErrorHandler,
        onTextDelta: @escaping (String) async -> Void,
        onAudioFrame: @escaping (Data, Int) async -> Void,
        onTurnEnd: @escaping (String) async -> Void
    ) {
        self.validator = validator
        self.errorHandler = errorHandler
        self.onTextDelta = onTextDelta
        self.onAudioFrame = onAudioFrame
        self.onTurnEnd = onTurnEnd
    }
    
    func receive(_ message: WebSocketMessage) async {
        switch message.type {
        case .aiTextDelta:
            if case .textDelta(let data) = message.data {
                await onTextDelta(data.text)
            }
            
        case .aiAudio:
            guard let turnID = message.turnID,
                  let sequence = message.sequence,
                  case .aiAudio(let base64) = message.data,
                  let audioData = Data(base64Encoded: base64) else {
                return
            }
            
            // 验证序列号
            let validation = await validator.validate(turnID: turnID, sequence: sequence)
            switch validation {
            case .valid:
                await onAudioFrame(audioData, sequence)
                
            case .duplicate:
                print("⚠️ Duplicate frame: \(sequence)")
                
            case .gapDetected(let missing):
                print("⚠️ Gap detected, missing: \(missing)")
                await onAudioFrame(audioData, sequence)
                
            case .outOfOrder:
                print("⚠️ Out of order frame: \(sequence)")
            }
            
        case .aiTurnEnd:
            if let turnID = message.turnID {
                await validator.reset(for: turnID)
                await onTurnEnd(turnID)
            }
            
        case .error:
            if case .error(let errorData) = message.data {
                let action = await errorHandler.handle(errorData)
                // 根据 action 处理
            }
            
        default:
            break
        }
    }
}
```

---

## 十、性能优化

### 10.1 消息批处理

对于高频消息（如音频帧），考虑批量发送：

```swift
actor MessageBatcher {
    private var pending: [WebSocketMessage] = []
    private let maxBatchSize = 10
    private let maxWaitTime: TimeInterval = 0.05  // 50ms
    
    private var timer: Task<Void, Never>?
    
    func enqueue(_ message: WebSocketMessage, transport: WebSocketTransport) async throws {
        pending.append(message)
        
        if pending.count >= maxBatchSize {
            try await flush(transport: transport)
        } else if timer == nil {
            timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(maxWaitTime * 1_000_000_000))
                try? await flush(transport: transport)
            }
        }
    }
    
    private func flush(transport: WebSocketTransport) async throws {
        guard !pending.isEmpty else { return }
        
        for message in pending {
            try await transport.send(message)
        }
        
        pending.removeAll()
        timer?.cancel()
        timer = nil
    }
}
```

### 10.2 消息压缩

对于大消息，考虑启用 WebSocket 压缩扩展：

```swift
let session = URLSession(configuration: .default)
var request = URLRequest(url: url)
request.addValue("permessage-deflate", forHTTPHeaderField: "Sec-WebSocket-Extensions")
```

---

## 总结

### 关键设计点

1. **简洁性**: JSON 格式，易于调试
2. **可扩展性**: `data` 字段支持任意类型
3. **顺序保证**: `sequence` 字段确保音频帧有序
4. **错误恢复**: `recoverable` 标志指导重试策略
5. **版本管理**: 协议版本协商，向后兼容

### 协议特性

- ✅ 类型安全的 Swift 模型
- ✅ 序列号管理与乱序检测
- ✅ 心跳保活机制
- ✅ 完善的错误码体系
- ✅ 版本冻结测试

下一步: [05_state_machine.md](05_state_machine.md) - 会话与对话状态机设计
