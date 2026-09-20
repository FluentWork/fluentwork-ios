# iOS TTS WebSocket 架构设计

**日期**: 2026-09-21  
**目标**: 从零设计 iOS 端的 TTS WebSocket 实时语音交互架构  
**视角**: 资深 iOS 开发专家，不考虑现有实现

---

## 设计背景

这是一个全新的设计，假设我们要为 iOS 应用构建一个实时语音交互系统：
- 用户说话 → 实时转写 → LLM 生成回复 → TTS 语音播放
- 全程通过 WebSocket 双工通信
- 要求低延迟、高可靠性、良好的用户体验

---

## 文档系列

### 核心设计文档（推荐阅读顺序）

| 文档 | 内容 | 读者 |
|------|------|------|
| **[01_requirements_and_constraints.md](01_requirements_and_constraints.md)** ⭐⭐⭐ | 需求分析与约束条件 | 所有人 |
| **[02_architecture_overview.md](02_architecture_overview.md)** ⭐⭐⭐ | 架构总览与分层设计 | 所有人 |
| **[03_audio_pipeline.md](03_audio_pipeline.md)** ⭐⭐ | 音频采集与播放链路 | iOS 开发者 |
| **[04_websocket_protocol.md](04_websocket_protocol.md)** ⭐⭐ | WebSocket 协议设计 | 全栈开发者 |
| **[05_state_machine.md](05_state_machine.md)** ⭐⭐ | 会话与对话状态机 | iOS 开发者 |
| **[06_error_handling.md](06_error_handling.md)** ⭐ | 错误处理与降级策略 | iOS 开发者 |
| **[07_threading_model.md](07_threading_model.md)** ⭐ | 并发模型与线程安全 | iOS 开发者 |
| **[08_implementation_roadmap.md](08_implementation_roadmap.md)** ⭐ | 实施路线图 | 技术负责人 |

### 深入主题

| 文档 | 内容 | 读者 |
|------|------|------|
| [09_audio_quality.md](09_audio_quality.md) | 音质优化与采样率选择 | 音频工程师 |
| [10_latency_optimization.md](10_latency_optimization.md) | 延迟优化策略 | 性能工程师 |
| [11_testing_strategy.md](11_testing_strategy.md) | 测试策略与质量保证 | QA + 开发者 |
| [12_monitoring_observability.md](12_monitoring_observability.md) | 可观测性设计 | SRE + 开发者 |

---

## 设计原则

### 1. 分层解耦

**三层架构**：
- **应用层** (UI/ViewModel): 用户交互、状态展示
- **业务层** (Service): 会话管理、状态机、策略
- **传输层** (Transport): WebSocket、音频 I/O、协议编解码

每层只依赖下层，上层变化不影响下层。

### 2. 接缝驱动

**关键接缝**：
- `AudioCaptureEngine`: 音频采集抽象（可替换为录音文件、测试数据）
- `AudioPlaybackEngine`: 音频播放抽象（可替换为录制、静音）
- `WebSocketTransport`: WebSocket 抽象（可替换为本地模拟、录制回放）
- `TTSProvider`: TTS 服务抽象（可多 vendor、A/B 测试）

每个接缝都可以被测试替身替换，不影响业务逻辑。

### 3. 协议冻结

**二进制协议一旦发布，永不改变**：
- 使用版本号隔离（v1, v2, ...）
- 新功能通过可选字段扩展
- 保持向后兼容性
- 测试锁定协议字节（防止意外改变）

### 4. 显式状态

**状态机而非布尔标志**：
```swift
enum SessionState {
    case idle
    case connecting
    case connected
    case active(turnID: String)
    case error(Error)
}
```

所有状态转换显式定义，非法转换被拒绝。

### 5. 结构性防御

**让常见错误在结构上不可能发生**：
- 音频序号由会话管理（不可能因重连而重置）
- Turn ID 生成规则单一（不可能在不同帧上不一致）
- 音频分类明确（AI / Ladder，不可能混淆）

### 6. Actor 并发模型

**Swift 并发优先**：
- 使用 `actor` 保护可变状态
- 使用 `async/await` 而非回调地狱
- 使用 `AsyncStream` 处理事件流
- 避免手动锁管理

### 7. SwiftUI 优先

**现代 iOS 开发**：
- SwiftUI 视图（声明式 UI）
- Combine / AsyncSequence（响应式数据流）
- Swift Package Manager（模块化）
- XCTest + XCTAssert（测试优先）

---

## 非目标（明确不做）

1. **不支持 UIKit** - 只支持 SwiftUI（iOS 15+）
2. **不支持离线模式** - 必须有网络连接
3. **不支持多会话** - 同时只有一个活跃会话
4. **不做音频后处理** - 降噪、回声消除由系统或后端处理
5. **不做通用框架** - 只为这个应用设计，不追求可复用

---

## 关键决策记录

| 决策 | 理由 | 权衡 |
|------|------|------|
| 使用 WebSocket 而非 HTTP | 双向实时通信，低延迟 | 复杂度高于 REST |
| 使用 AVAudioEngine 而非 AudioUnit | 高层 API，易用性好 | 灵活性低于 AudioUnit |
| 使用 Opus 编码 | 高质量、低码率、开源 | 需要集成第三方库 |
| 使用 Actor 而非 GCD | 结构化并发，编译器检查 | iOS 15+ only |
| 使用 AsyncStream 而非 Combine | 更简洁，与 async/await 集成好 | 生态不如 Combine 成熟 |

---

## 快速导航

### 我想了解...

**系统整体架构** → [02_architecture_overview.md](02_architecture_overview.md)

**音频如何采集和播放** → [03_audio_pipeline.md](03_audio_pipeline.md)

**WebSocket 协议格式** → [04_websocket_protocol.md](04_websocket_protocol.md)

**会话状态如何管理** → [05_state_machine.md](05_state_machine.md)

**如何处理网络错误** → [06_error_handling.md](06_error_handling.md)

**并发安全如何保证** → [07_threading_model.md](07_threading_model.md)

**如何分阶段实施** → [08_implementation_roadmap.md](08_implementation_roadmap.md)

---

## 参考资料

- **Backend 设计文档**: `fluentwork-backend/docs/94-99_*` (重构系列)
- **Backend 审核报告**: `fluentwork-backend/docs/103_tts_wss_architecture_audit/`
- **Apple 文档**: AVAudioEngine, URLSessionWebSocketTask, Actor
- **协议标准**: Opus codec, WebSocket RFC 6455
