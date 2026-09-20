# iOS TTS WebSocket 架构设计总结

**日期**: 2026-09-21  
**分支**: feature/tts-wss-architecture-design  
**状态**: 初步设计完成

---

## 完成内容

已创建 iOS TTS WebSocket 系统的核心架构设计文档：

### 📋 文档清单

1. **[README.md](200_tts_wss_architecture_design/README.md)** - 设计总览与导航
2. **[01_requirements_and_constraints.md](200_tts_wss_architecture_design/01_requirements_and_constraints.md)** ⭐⭐⭐ - 需求分析与约束条件
3. **[02_architecture_overview.md](200_tts_wss_architecture_design/02_architecture_overview.md)** ⭐⭐⭐ - 三层架构与核心组件
4. **[03_audio_pipeline.md](200_tts_wss_architecture_design/03_audio_pipeline.md)** ⭐⭐ - 音频采集与播放链路

---

## 核心设计理念

### 1. 分层解耦

**三层架构**:
```
Presentation Layer (SwiftUI + ViewModel)
        ↓
Domain Layer (VoiceSessionService + State Machine)
        ↓
Infrastructure Layer (WebSocket + AudioEngine)
```

### 2. Actor 并发模型

- 所有状态管理使用 `actor` 保护
- 使用 `async/await` 替代回调地狱
- 使用 `AsyncStream` 处理事件流
- 编译器保证线程安全

### 3. 协议驱动设计

```swift
protocol WebSocketTransport: Actor { ... }
protocol AudioEngine: Actor { ... }
protocol TTSProvider: Actor { ... }
```

每个关键组件都可被测试替身替换。

### 4. 显式状态机

```swift
enum SessionState {
    case idle
    case connected
    case recording(turnID: String)
    case processing(turnID: String)
    case playing(turnID: String)
    case error(Error)
}
```

所有状态转换显式定义，非法转换被拒绝。

---

## 关键技术决策

| 决策 | 理由 | 权衡 |
|------|------|------|
| **iOS 15+** | Actor、AsyncStream、AVAudioEngine 改进 | 不支持旧设备 |
| **Actor 而非 GCD** | 编译器保证线程安全 | 仅 iOS 15+ |
| **Opus 编码** | 高质量、低码率、开源 | 需要集成第三方库 |
| **16kHz 采样率** | 语音识别标准，平衡质量与带宽 | 非 Hi-Fi 音质 |
| **20ms 帧大小** | 平衡延迟与效率 | 固定值 |
| **AsyncStream 而非 Combine** | 更简洁，与 async/await 集成好 | 生态较新 |

---

## 性能目标

| 指标 | 目标值 | 测量方法 |
|------|--------|---------|
| 首帧延迟 | < 300ms | 用户松开 → 听到第一个音频块 |
| 端到端延迟 | < 1.5s | 用户松开 → 听到完整回复开始 |
| 音频块间隔 | 20-50ms | 相邻音频块播放间隔 |
| 崩溃率 | < 0.1% | 每 1000 次会话 < 1 次 |
| 内存占用 | < 50MB | Instruments 测量 |
| CPU 占用 | < 20% | 音频处理峰值 |

---

## 核心组件设计

### Presentation Layer

```swift
ConversationView (SwiftUI)
    ↓
ConversationViewModel (@MainActor, ObservableObject)
    - @Published var turns: [Turn]
    - @Published var sessionState: SessionState
    - @Published var isRecording: Bool
```

### Domain Layer

```swift
VoiceSessionService (actor)
    - 会话生命周期管理
    - 状态机控制
    - 业务规则执行
    - 错误处理策略

SessionStateManager (struct)
    - 状态转换验证
    - 转换规则表
```

### Infrastructure Layer

```swift
URLSessionWebSocketTransport (actor)
    - WebSocket 连接管理
    - 消息收发
    - 自动重连

AVAudioEngineImpl (actor)
    - 音频采集 (16kHz, mono, 20ms frames)
    - Opus 编码/解码
    - 播放队列管理
```

---

## 音频链路

### 上行（采集 → 传输）

```
Microphone → AVAudioEngine.inputNode
    → 重采样 (48kHz → 16kHz)
    → 格式转换 (Float32 → Int16)
    → 分帧 (320 samples / 20ms)
    → Opus 编码 (640 bytes → ~40 bytes)
    → Base64 + JSON
    → WebSocket
    → Backend
```

### 下行（接收 → 播放）

```
Backend → WebSocket
    → JSON 解析
    → Base64 解码
    → 按 sequence 排序
    → Opus 解码 (~40 bytes → 640 bytes)
    → Int16 → Float32
    → AVAudioPCMBuffer
    → AVAudioPlayerNode
    → Speaker
```

---

## 待完成文档

以下文档计划在后续迭代中完成：

- [ ] 04_websocket_protocol.md - WebSocket 协议设计
- [ ] 05_state_machine.md - 会话与对话状态机
- [ ] 06_error_handling.md - 错误处理与降级策略
- [ ] 07_threading_model.md - 并发模型与线程安全
- [ ] 08_implementation_roadmap.md - 实施路线图
- [ ] 09_audio_quality.md - 音质优化
- [ ] 10_latency_optimization.md - 延迟优化
- [ ] 11_testing_strategy.md - 测试策略
- [ ] 12_monitoring_observability.md - 可观测性设计

---

## 与 Backend 的对照

### Backend 重构启发

从 `fluentwork-backend/docs/94-99` 和 `103_audit` 学到的经验：

1. **结构性防御**: 让常见错误在结构上不可能发生
   - Backend: SeqAllocator 防止序号回退
   - iOS: 状态机拒绝非法转换

2. **接缝驱动**: 每个关键组件都可测试替换
   - Backend: VoiceProvider 协议
   - iOS: WebSocketTransport / AudioEngine 协议

3. **显式状态**: 状态机而非布尔标志
   - Backend: Turn 状态机
   - iOS: SessionState 枚举

4. **协议冻结**: 一旦发布永不改变
   - Backend: TestSchemaV1BytesAreFrozen
   - iOS: 版本化消息格式

### 差异点

| 方面 | Backend (Go) | iOS (Swift) |
|------|-------------|-------------|
| 并发模型 | goroutine + channel + mutex | Actor + async/await |
| 状态保护 | sync.Mutex 手动加锁 | Actor 自动隔离 |
| 事件流 | channel | AsyncStream |
| 错误处理 | error 返回值 | throws + Result |
| 测试 | Table-driven tests | XCTest + Mock protocols |

---

## 下一步行动

### 立即行动（本周）

1. **完善协议设计** - 编写 04_websocket_protocol.md
2. **细化状态机** - 编写 05_state_machine.md
3. **评审设计** - 与团队讨论架构方案

### 短期计划（两周内）

4. **实施路线图** - 编写 08_implementation_roadmap.md
5. **创建原型** - 实现核心 actor 和协议
6. **单元测试框架** - 搭建测试基础设施

### 中期目标（一个月）

7. **MVP 实现** - 完整的录音 → 播放流程
8. **真机验证** - 在 iPhone 上测试音频质量
9. **性能优化** - 达到延迟目标

---

## 参考资料

- **Backend 设计文档**: `fluentwork-backend/docs/94-99_*`
- **Backend 审核报告**: `fluentwork-backend/docs/103_tts_wss_architecture_audit/`
- **Apple 文档**: 
  - [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
  - [URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)
  - [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- **Opus Codec**: [opus-codec.org](https://opus-codec.org/)

---

## 总结

已完成 iOS TTS WebSocket 系统的初步架构设计，包括：

✅ 需求分析与技术约束  
✅ 三层架构定义  
✅ 核心组件接口设计  
✅ 音频采集与播放链路  
✅ Actor 并发模型  
✅ 状态机设计  

这是一个**全新的设计**，基于资深 iOS 开发专家的视角，充分利用 Swift 现代特性（Actor、async/await、AsyncStream），不受现有实现的限制。

设计遵循 Clean Architecture、SOLID 原则，强调可测试性、可维护性和性能。
