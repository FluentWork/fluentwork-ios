# I13 客户端 ASR 回灌实现总结

**对应 Backend ticket**：B13  
**完成日期**：2026-09-01  
**状态**：✅ 核心实现完成，待测试与联调

---

## 一、实现总览

### 1.1 完成的组件

| 组件 | 文件 | 状态 |
|---|---|---|
| 协议定义 | `ClientASRTranscriber.swift` | ✅ |
| Apple Speech 实现 | `AppleSpeechClientASRTranscriber.swift` | ✅ |
| Volcengine 占位 | `VolcengineClientASRTranscriber.swift` | ⚠️ 占位 |
| Debug 实现 | `RawClientASRTranscriber.swift` | ✅ |
| Middleware 集成 | `SpeechSessionMiddleware.swift` | ✅ |
| **PCM 缓冲** | `SpeechSessionMiddleware.swift:133-208` | ✅ **新增** |
| DI 绑定 | `AppDependencies.swift:385` | ✅ |
| 网络层支持 | `DefaultSpeechSessionClient.swift:75` | ✅ |

### 1.2 关键改动

#### PCM 音频缓冲实现 (SpeechSessionMiddleware.swift)

**新增逻辑**（133-208 行）：

```swift
.task(id: SpeechSessionTaskID.audioEngineEvents) {
    // B13: Buffer PCM chunks during speech for client ASR transcription
    var pcmBuffer: [Data] = []
    var isCapturingSpeech = false
    
    for await event in audioEngine.events() {
        switch event {
        case .speechStarted:
            pcmBuffer.removeAll()
            isCapturingSpeech = true
            // ... send user.speech.start
        
        case .speechEnded:
            isCapturingSpeech = false
            
            let clientASRText = await transcribeWithClientASR(
                transcriber: clientASRTranscriber,
                tracker: tracker,
                turnID: turnID,
                pcmChunks: pcmBuffer  // ← 传入缓冲的 PCM
            )
            
            try await speechClient.sendSpeechBoundary(
                started: false,
                turnID: turnID,
                text: clientASRText  // ← 携带 ASR 结果
            )
            
            pcmBuffer.removeAll()
        
        case let .pcmChunk(data):
            if isCapturingSpeech {
                pcmBuffer.append(data)  // ← 缓冲 PCM
            }
            try await speechClient.sendAudioPCM(data)
        
        case .failed:
            // ... error handling
        }
    }
}
```

**设计要点**：

1. **缓冲时机**：只在 `speechStarted` → `speechEnded` 期间缓冲
2. **内存管理**：每个 turn 结束后清空 buffer
3. **并发安全**：`pcmBuffer` 在 `.task` 闭包内，无需同步
4. **向后兼容**：PCM 仍正常发送给 Backend（保留 server-side ASR 路径）

#### transcribeWithClientASR 修复 (SpeechSessionMiddleware.swift:285-293)

**修改前**（占位实现）：
```swift
let pcmStream = AsyncStream<Data> { continuation in
    // TODO(B13): Wire actual PCM buffer
    continuation.finish()  // ← 空流
}
```

**修改后**（真实实现）：
```swift
let pcmStream = AsyncStream<Data> { continuation in
    for chunk in pcmChunks {
        continuation.yield(chunk)  // ← 重放缓冲的 PCM
    }
    continuation.finish()
}
```

---

## 二、架构说明

### 2.1 数据流

```
LiveAudioEngine
    │ VAD 检测到语音开始
    ├──> .speechStarted
    │       └──> Middleware: pcmBuffer.removeAll() + isCapturingSpeech = true
    │
    ├──> .pcmChunk(data)  ← 持续产生
    │       ├──> speechClient.sendAudioPCM(data)  [到 Backend]
    │       └──> if isCapturingSpeech: pcmBuffer.append(data)  [缓冲到本地]
    │
    └──> .speechEnded
            ├──> transcribeWithClientASR(pcmChunks: pcmBuffer)
            │       ├──> AsyncStream 重放 pcmBuffer
            │       ├──> AppleSpeechClientASRTranscriber.transcribe()
            │       │       └──> SFSpeechRecognizer (800ms 超时)
            │       └──> 返回 text 或 nil
            │
            └──> speechClient.sendSpeechBoundary(text: clientASRText)
                    └──> Backend 收到带 text 的 user.speech.end
```

### 2.2 超时机制

```swift
// 800ms 超时竞速（transcribeWithClientASR 内部）
try await withThrowingTaskGroup(of: String?.self) { group in
    group.addTask {
        try await transcriber.transcribe(pcm: pcmStream)
    }
    
    group.addTask {
        try await Task.sleep(for: .milliseconds(800))
        return nil  // 超时信号
    }
    
    // 第一个完成的任务获胜
    guard let result = try await group.next() else {
        throw ClientASRError.timeout
    }
    
    group.cancelAll()
    return result
}
```

### 2.3 错误处理

| 场景 | iOS 行为 | Backend 行为 |
|---|---|---|
| ASR 成功 | 发送 `text="你好"`，埋点 `speech_client_asr_completed` | 收到 text，B12 hit detection 使用 |
| ASR 超时 | 发送 `text=nil`，埋点 `speech_client_asr_skipped(timeout)` | 收到 nil，fallback 到 server-side ASR |
| ASR 不可用 | 发送 `text=nil`，埋点 `speech_client_asr_skipped(not_available)` | 同上 |
| ASR 失败 | 发送 `text=nil`，埋点 `speech_client_asr_failed` | 同上 |
| Gate 开启 + 空 text | N/A（iOS 不会发空字符串） | 返回 `error.client_asr_required` |

---

## 三、已实现的埋点

### 3.1 成功路径

```swift
tracker.track(
    event: "speech_client_asr_completed",
    properties: [
        "turn_id": "turn-1",
        "elapsed_ms": "320",
        "text_length": "12",
        "source": "ios",
    ]
)
```

### 3.2 跳过路径

```swift
tracker.track(
    event: "speech_client_asr_skipped",
    properties: [
        "turn_id": "turn-1",
        "reason": "timeout",  // or "not_available"
        "source": "ios",
    ]
)
```

### 3.3 失败路径

```swift
tracker.track(
    event: "speech_client_asr_failed",
    properties: [
        "turn_id": "turn-1",
        "error_code": "authorization_denied",
        "source": "ios",
    ]
)
```

---

## 四、测试计划

### 4.1 单元测试（待补充）

| 测试名 | 验证点 | 优先级 |
|---|---|---|
| `testPCMBufferCapturesDuringTurn` | `pcmBuffer` 在 speech 期间正确缓冲 | P0 |
| `testPCMBufferClearsAfterTurn` | turn 结束后 buffer 被清空 | P0 |
| `testClientASRSuccessWithinTimeout` | 500ms 内完成 → text 非空 | P0 |
| `testClientASRTimeoutFallsBackToNil` | 800ms 超时 → text=nil | P0 |
| `testClientASRNotAvailableFallsBackToNil` | ASR 引擎不可用 → text=nil | P0 |
| `testMiddlewareEmitsCorrectTelemetry` | 三个埋点事件正确触发 | P1 |

### 4.2 集成测试（手动验证）

| 场景 | 步骤 | 期望结果 |
|---|---|---|
| **正常 ASR** | 1. 启动 app<br>2. 说话 "你好世界"<br>3. 停止说话 | Xcode console 看到 `speech_client_asr_completed`，text_length=12 |
| **超时 fallback** | 1. 说很长的句子（> 10 秒）<br>2. 停止说话 | 看到 `speech_client_asr_skipped(timeout)` |
| **权限拒绝** | 1. 设置中关闭语音识别权限<br>2. 说话 | 看到 `speech_client_asr_failed(authorization_denied)` |

---

## 五、跨端联调准备

### 5.1 iOS 侧配置

```swift
// AppDependencies.swift (无需修改，默认已正确)
var clientASRTranscriber: Factory<ClientASRTranscriber> {
    self {
        AppleSpeechClientASRTranscriber()  // ← 默认实现
    }
}
```

### 5.2 Backend 侧配置

```bash
# 联调阶段保持 gate 关闭
export VOICE_CLIENT_ASR_REQUIRED=false

# Backend logs 中应该能看到：
# INFO voice user speech frame type=user.speech.end stage=asr
# (检查日志确认收到 text 字段)
```

### 5.3 联调验证清单

- [ ] iOS Xcode console 能看到 `speech_client_asr_completed` 埋点
- [ ] Backend logs 能看到 `user.speech.end` 帧携带 `text` 字段
- [ ] Backend B12 hit detection 使用 client ASR 结果（而非空）
- [ ] ASR 超时时，Backend 能正常处理 `text=nil`（server-side fallback）
- [ ] 当 Backend gate 开启且 iOS 发送空 text 时，收到 `error.client_asr_required`

---

## 六、已知限制

### 6.1 Volcengine SDK 未集成

**当前状态**：`VolcengineClientASRTranscriber` 抛 `.notAvailable`

**影响**：无（Apple Speech 已足够支撑 Phase 2-4）

**后续**：B14 ticket 独立完成 Volcengine SDK 接入

### 6.2 FeatureFlag 缺失

**当前状态**：client ASR 是**始终启用**的（通过 DI 默认注入）

**影响**：无法快速关闭 client ASR 进行 A/B 测试

**建议**：Phase 3 前补充 `enableClientASR` flag：

```swift
// FeatureFlags.swift
public enum AppFeatureFlag: String {
    // ... existing ...
    case enableClientASR  // ← 新增
}

// AppDependencies.swift
var clientASRTranscriber: Factory<ClientASRTranscriber> {
    self {
        let isEnabled = Container.shared.featureFlags().isEnabled(.enableClientASR)
        if isEnabled {
            return AppleSpeechClientASRTranscriber()
        } else {
            return RawClientASRTranscriber()  // 返回空字符串，fallback 到 server
        }
    }
}
```

### 6.3 内存占用优化

**当前实现**：`pcmBuffer` 在内存中累积所有 PCM chunk

**典型占用**：
- 1 秒语音 ≈ 32KB（16kHz mono PCM16）
- 10 秒语音 ≈ 320KB
- 30 秒语音 ≈ 960KB

**风险**：用户说很长句子时内存占用较高

**后续优化**（可选）：
- 限制 buffer 最大容量（如 30 秒）
- 使用滑动窗口（只保留最近 N 秒）
- 流式 ASR（边说边识别，无需缓冲）

---

## 七、Phase 2-4 推进时间表

### Phase 2: 本地联调（2026-09-02 ~ 09-03）

**前置条件**：
- ✅ iOS PCM 缓冲实现完成
- ⏳ iOS 单元测试编写（P0 优先级 5 个测试）

**交付物**：
- 联调报告（4 个 Case 验证结果）
- Backend logs 截图（确认收到 text 字段）
- iOS 埋点截图（确认三个事件触发）

### Phase 3: 10% 灰度（2026-09-04 ~ 09-10）

**前置条件**：
- ✅ Phase 2 联调通过
- ⏳ 添加 iOS FeatureFlag `enableClientASR`
- ⏳ Backend 增加监控指标（Prometheus + Grafana）

**观察指标**：
- `speech_client_asr_completed` > 80%
- `speech_client_asr_failed` < 5%
- Backend `user.speech.end.with_text` 比例 > 75%

**决策门槛**：
- ✅ 继续 Phase 4：成功率 > 80%
- ❌ 回退：失败率 > 10% 或用户投诉

### Phase 4: 全量 + Gate 开启（2026-09-11 ~ 09-17）

**阶段 A**（09-11 ~ 09-13）：
- iOS `enableClientASR` 100% 启用
- Backend gate 仍为 `false`（观察期）

**阶段 B**（09-14 ~ 09-15）：
- Backend gate 10% pod 开启 `VOICE_CLIENT_ASR_REQUIRED=true`
- 观察 `error.client_asr_required` 错误率 < 1%

**阶段 C**（09-16）：
- Backend gate 全量开启
- 监控 B12 badge 命中率（应 ±5% 内持平）

---

## 八、回滚计划

### iOS 侧快速回滚

```swift
// 方案 1: Remote config 关闭 flag
enableClientASR:
  enabled: false
  rollout: 0%

// 方案 2: 代码强制使用 RawClientASRTranscriber
container.clientASRTranscriber.register {
    RawClientASRTranscriber()  // 返回空字符串，fallback 到 server
}
```

**恢复时间**：< 10 分钟（Remote config 推送）

### Backend 侧快速回滚

```bash
export VOICE_CLIENT_ASR_REQUIRED=false
kubectl rollout restart deployment/voice-gateway
```

**恢复时间**：< 5 分钟

---

## 九、文档更新清单

完成后需同步更新：

- [ ] `fluentwork-backend/docs/22_B13_client_asr_回灌_实现说明.md`（添加联调结果 §5.2）
- [ ] `fluentwork-meta/docs/runbooks/voice_gateway_deployment.md`（环境变量说明）
- [ ] iOS `CHANGELOG.md`（记录 I13 实现）
- [ ] Backend `CHANGELOG.md`（记录 B13 实现）

---

## 十、成功标准

### ✅ 实现完成（当前状态）

- ✅ PCM 缓冲逻辑实现
- ✅ `transcribeWithClientASR` 使用真实 PCM 数据
- ✅ Swift 编译通过
- ✅ 三个埋点事件完整

### ⏳ Phase 2 前完成

- [ ] 编写 5 个单元测试
- [ ] 本地手动测试（正常/超时/权限拒绝 三个场景）
- [ ] Backend 联调（验证 4 个 Case）

### ⏳ Phase 3 前完成

- [ ] 添加 FeatureFlag `enableClientASR`
- [ ] Backend 监控 dashboard
- [ ] 灰度配置文件（Firebase / Helm）

### ⏳ Phase 4 完成标志

- [ ] iOS 100% 启用
- [ ] Backend gate 100% 启用
- [ ] `error.client_asr_required` < 1%
- [ ] B12 badge 命中率持平（±5%）

---

**最后更新**：2026-09-01  
**负责人**：iOS 团队  
**下次审查**：Phase 2 完成后（2026-09-03）
