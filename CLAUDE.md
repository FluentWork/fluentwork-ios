# FluentWork iOS — CLAUDE.md

> 本文件是 iOS Agent 的主要上下文文档。阅读顺序：先 CLAUDE.md → 再 AGENTS.md → 最后具体模块文档。

## 仓库角色

`fluentwork-ios` 是 FluentWork 的 SwiftUI iOS 应用，负责：
- **语音采集** — AVAudioEngine + VAD 能量检测
- **语音会话** — SpeechSessionMachine 状态机
- **WSS 通信** — URLSessionSocketTransport
- **UI 展示** — SpeakingRoom 等功能模块

## 核心架构

### 语音会话流程

```
LiveAudioEngine (音频采集)
    ↓ PCM 16kHz
SpeechSessionMachine (状态机)
    ↓ 副作用
SpeechSessionMiddleware (副作用解释)
    ↓ WSS 帧
URLSessionSocketTransport (WebSocket)
    ↓
Voice Gateway (Backend)
```

### 关键组件

| 组件 | 文件 | 职责 |
|------|------|------|
| LiveAudioEngine | `FluentWorkCore/Services/` | AVAudioEngine 音频采集、VAD |
| SpeechSessionMachine | `FluentWorkCore/SpeechSession/` | 纯状态机 |
| SpeechSessionMiddleware | `FluentWorkCore/Architecture/Middleware/` | 副作用解释、WSS 通信 |
| URLSessionSocketTransport | `FluentWorkNetworking/Socket/` | WebSocket 传输 |

### SpeechSessionMachine 状态

```
IDLE → CONNECTING → WAITING_USER → RECORDING → PROCESSING → WAITING_USER
              ↓            ↓            ↓           ↓
           FAILED       FAILED       FAILED      FAILED
```

### 关键协议帧 (来自 Backend)

| 帧类型 | 描述 | iOS 处理 |
|--------|------|----------|
| `session.ready` | Session 就绪 | 更新状态 |
| `ai.text.delta` | AI 文本增量 | 更新 UI |
| `ai.turn.end` | Turn 结束 (B15 带 outcome) | 退出 PROCESSING |
| `client.asr.transcription` | ASR 中继 | 备用文本 |
| `feedback.badge` | Badge 命中 | 显示 Badge |
| `error` | 错误 | 错误处理 |

## 开发入门

### 1. 环境准备

```bash
# 克隆
git clone https://github.com/FluentWork/fluentwork-ios.git
cd fluentwork-ios

# XcodeGen 生成
xcodegen generate

# 安装依赖
xcodebuild -resolvePackageDependencies -scheme FluentWork
```

### 2. 构建和运行

```bash
# 构建
xcodebuild -scheme FluentWork -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# 测试
xcodebuild test -scheme FluentWork -destination 'platform=iOS Simulator,name=iPhone 16'
```

### 3. 关键测试

```bash
# 运行 SpeechSessionMachine 测试
xcodebuild test -scheme FluentWorkCoreTests \
  -only-testing:FluentWorkCoreTests/SpeechSessionMachineTests

# 运行 Middleware 测试
xcodebuild test -scheme FluentWorkCoreTests \
  -only-testing:FluentWorkCoreTests/SpeechSessionMiddlewareTests
```

## 关键模块详解

### LiveAudioEngine

**职责**:
- 使用 AVAudioEngine 采集麦克风音频
- VAD (Voice Activity Detection) 能量检测
- 输出 16kHz mono PCM 数据

**关键接口**:
```swift
public protocol AudioEngine: Actor {
    var events: AsyncStream<AudioEngineEvent> { get }
    func start() async throws
    func stop() async
}
```

**事件**:
```swift
public enum AudioEngineEvent: Sendable {
    case speechStarted
    case speechEnded
    case audioChunk(Data)  // PCM 16kHz mono
}
```

### SpeechSessionMachine

**职责**:
- 纯状态机，无副作用
- 根据输入事件和当前状态转换
- 产生副作用 (SideEffect) 供 Middleware 执行

**状态**:
```swift
public enum SpeechSessionPhase: Equatable {
    case idle
    case connecting
    case waitingUser
    case recording
    case processing
    case failed(String)
}
```

**副作用**:
```swift
public enum SpeechSessionSideEffect: Sendable {
    case connect(ticket: String)
    case startSession
    case userStarted
    case userEnded
    case sendAudioChunk(Data)
    case disconnect
}
```

### SpeechSessionMiddleware

**职责**:
- 解释 SpeechSessionMachine 的副作用
- WSS 帧发送和接收
- B15: 70s Turn Timeout 兜底

**关键行为**:
```swift
// B15: Turn Timeout
// transport task 中等待 70s
// 若 ai.turn.end 先到，disarm() 取消计时器
// 若超时先到，触发 .failed("turn_timeout")
```

### URLSessionSocketTransport

**职责**:
- WebSocket 连接管理
- 帧编解码 (JSON ↔ WSS)
- 重连逻辑

**帧类型映射**:
```swift
WSControlFrame:
  case auth(ticket: String)
  case sessionStart
  case userSpeechStart
  case userSpeechEnd(text: String, turnID: String)
  case sessionEnd(reason: String)
```

## B15 相关改动

### Item 1.2: ai.turn.end 带 outcome

Backend 已实现 `outcome` 字段，iOS 需要：

1. 解码带 `outcome` 的 `ai.turn.end` 帧
2. `outcome == "timeout"` 时触发 `.failed("turn_timeout")`

```swift
// WSControlFrame 解码
case let .aiTurnEnd(turnID, outcome):
    turnTimeoutTracking?.disarm()
    if outcome == "timeout" {
        dispatch(.speechRoom(.session(.failed("turn_timeout"))))
    }
```

### Item 1.2: provider_audio_failed 错误处理

收到 `error.code == "provider_audio_failed"` 时：
- 触发 `.failed("provider_audio_failed")`
- 关闭 WSS 连接

## 高风险区域

修改以下代码前需要额外审查：

1. **LiveAudioEngine** — 音频采集逻辑复杂
2. **SpeechSessionMachine** — 状态机契约
3. **SpeechSessionMiddleware** — 副作用解释器
4. **URLSessionSocketTransport** — WSS 协议处理

## 测试规范

1. **每个模块有对应测试**
2. **使用 @Test (Swift Testing)**
3. **Mock SpeechSessionMachine 的 SideEffect 解释**
4. **Integration Tests 使用 Stub Transport**

```swift
@Test func testRecordingPhaseTransitionsToProcessingOnUserEnded() {
    var machine = SpeechSessionMachine()
    
    machine.dispatch(.startSession)  // → CONNECTING
    machine.dispatch(.sessionReady)  // → WAITING_USER
    machine.dispatch(.userStarted)   // → RECORDING
    machine.dispatch(.userEnded)     // → PROCESSING
    
    #expect(machine.phase == .processing)
}
```

## 相关资源

### 内部文档

- `FluentWork/Architecture/` — 架构设计
- `FluentWork/Documentation/` — 详细文档

### 外部依赖

- **Backend**: `fluentwork-backend` — WSS 网关服务
- **Meta**: `fluentwork-meta` — 项目治理和文档

### 项目蓝图

完整的系统架构图请参考：
`fluentwork-meta/docs/80_项目整体蓝图.md`

## 环境变量 (Development)

| 变量 | 描述 |
|------|------|
| `VOICE_GATEWAY_URL` | WSS 网关地址 (默认: `ws://localhost:8081/v1/voice`) |
| `APP_ENV` | 环境 (`development`/`staging`/`production`) |

## 问题排查

### WSS 连接失败

1. 检查 voice-gateway 是否运行 (`lsof -i :8081`)
2. 检查 `VOICE_GATEWAY_URL` 是否正确
3. 检查网络权限

### 音频不采集

1. 检查麦克风权限
2. 检查 AVAudioSession 配置
3. 检查 VAD threshold

### Badge 不显示

1. 检查 Backend BadgeEmitter 配置
2. 检查 Corpus 是否正确加载
3. 检查 `feedback.badge` 帧是否收到

## 贡献指南

1. **Fork** 并创建 feature branch
2. **编写测试** 覆盖新功能
3. **保持最小 diff** — 避免不必要的重构
4. **提交前运行测试** 确保通过
5. **创建 PR** 并等待 Code Review
