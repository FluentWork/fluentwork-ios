# SpeechSessionMiddleware Client ASR Tests

## 测试概述

本测试套件验证 **B13: Client ASR with PCM Buffer** 功能，确保 iOS 客户端能够：
- 在语音轮次中缓冲 PCM 数据
- 调用客户端 ASR 进行转录
- 正确处理超时和失败场景
- 发送完整的遥测事件

## 测试架构

### Mock 组件

#### 1. RecordingClientASRTranscriber
模拟客户端 ASR 转录器，可控制延迟和返回结果：

```swift
let transcriber = RecordingClientASRTranscriber()
transcriber.delay = .milliseconds(100)  // 模拟转录延迟
transcriber.result = "test transcription"  // 模拟转录结果
```

#### 2. RecordingSpeechClient
记录所有 `sendSpeechBoundary` 调用：

```swift
let calls = await speechClient.speechBoundaryCalls
// 验证 started、turnID、text 参数
```

#### 3. RecordingTracker
捕获遥测事件：

```swift
let events = await tracker.getEvents()
let asrEvents = events.filter { $0.name == "speech_client_asr_completed" }
```

#### 4. ControllableAudioEngine
手动发送音频事件：

```swift
audioEngine.emit(.speechStarted)
audioEngine.emit(.pcmChunk(Data([1, 2, 3])))
audioEngine.emit(.speechEnded)
```

### 依赖注入

使用 `makeTestContainer` 将 mock 注入到 Redux store：

```swift
let container = makeTestContainer(
    audioEngine: audioEngine,
    speechClient: speechClient,
    tracker: tracker,
    clientASRTranscriber: transcriber
)
let store = AppStoreFactory.make(container: container)
```

## 测试用例详解

### Test 1: clientASRSuccessWithinTimeout ✅
**目的**: 验证 ClientASR 在超时前成功返回

**流程**:
1. 配置转录器延迟 100ms（< 500ms 超时）
2. 发送语音轮次：开始 → PCM 块 → 结束
3. 等待 600ms 让异步任务完成
4. 验证：
   - `sendSpeechBoundary` 被调用，`text` = "test transcription"
   - 转录器收到正确的 PCM 数据

**关键断言**:
```swift
#expect(calls[1].text == "test transcription")
#expect(transcriberCalls[0].pcmChunks.count == 2)
```

---

### Test 2: clientASRTimeoutFallsBackToNil ✅
**目的**: 验证 ClientASR 超时后回退到 server ASR

**流程**:
1. 配置转录器延迟 1000ms（> 500ms 超时）
2. 发送语音轮次
3. 验证：`sendSpeechBoundary` 的 `text` = `nil`

**关键断言**:
```swift
#expect(calls[1].text == nil)  // 超时回退
```

**超时机制**:
```swift
let clientASRTask = Task {
    return try await transcriber.transcribe(pcmChunks: pcmChunks, turnID: turnID)
}
let timeoutTask = Task {
    try await Task.sleep(for: .milliseconds(500))
    clientASRTask.cancel()
    return nil
}
```

---

### Test 3: clientASRNotAvailableFallsBackToNil ✅
**目的**: 验证 ClientASR 不可用时的回退逻辑

**流程**:
1. 转录器返回 `nil`（模拟不可用）
2. 发送语音轮次
3. 验证：`text` = `nil`

**使用场景**:
- 设备不支持 Speech Recognition
- 用户未授权麦克风权限
- 系统资源不足

---

### Test 4: pcmBufferCapturesDuringTurn ✅
**目的**: 验证 PCM 缓冲区正确捕获数据

**流程**:
```
speechStarted (清空缓冲)
  ↓
pcmChunk(Data([1,2,3]))  → 追加到缓冲
  ↓
pcmChunk(Data([4,5,6]))  → 追加到缓冲
  ↓
pcmChunk(Data([7,8,9]))  → 追加到缓冲
  ↓
speechEnded (传给 ClientASR)
```

**验证点**:
- 缓冲区包含所有 3 个块
- 数据顺序正确
- 内容完整

**关键断言**:
```swift
#expect(calls[0].pcmChunks.count == 3)
#expect(calls[0].pcmChunks[0] == Data([1, 2, 3]))
```

---

### Test 5: pcmBufferClearsAfterTurn ✅
**目的**: 验证缓冲区在轮次间正确清空

**场景**: 两轮连续语音

**验证**:
```swift
// 第一轮：2 个块
// 第二轮：3 个块
#expect(calls[1].pcmChunks.count == 3)  // 不包含第一轮的数据
```

**防止的问题**:
- ❌ 内存泄漏
- ❌ 数据串扰
- ❌ 缓冲区无限增长

---

### Test 6: pcmNotBufferedOutsideSpeechTurn ✅
**目的**: 验证语音轮次外不缓冲 PCM

**流程**:
```
pcmChunk (在 speechStarted 之前) → 不缓冲
  ↓
speechStarted
  ↓
speechEnded
  ↓
验证：ClientASR 收到空数组
```

**防止的问题**:
- ❌ 捕获用户隐私数据（非语音时段）
- ❌ 浪费内存和网络带宽
- ❌ 误识别背景噪音

---

### Test 7: telemetryEventsEmittedCorrectly ✅
**目的**: 验证遥测事件正确发送

**验证的事件**:
```javascript
{
  event: "speech_client_asr_completed",
  properties: {
    turn_id: "turn-1",
    text_length: "18",
    elapsed_ms: "123",  // 实际延迟
    source: "ios"
  }
}
```

**用途**:
- 监控 ClientASR 性能
- 计算命中率
- 分析超时原因
- A/B 测试

---

## PCM 缓冲实现

### 数据结构

```swift
var pcmBuffer: [Data] = []  // 简单动态数组
var isCapturingSpeech = false  // 缓冲开关
```

### 状态机

```
初始状态: isCapturingSpeech = false, pcmBuffer = []
    ↓
speechStarted: 
  - pcmBuffer.removeAll()  ← 清空旧数据
  - isCapturingSpeech = true
    ↓
pcmChunk × N:
  - if isCapturingSpeech { pcmBuffer.append(data) }
    ↓
speechEnded:
  - isCapturingSpeech = false
  - 调用 ClientASR(pcmBuffer)
  - pcmBuffer.removeAll()  ← 清空已用数据
```

### 为什么不用环形缓冲区？

| 环形缓冲区 | 动态数组 | 选择 |
|-----------|---------|------|
| 固定大小 | 动态大小 | ✅ 需要完整数据 |
| 覆盖旧数据 | 追加新数据 | ✅ 不能丢失 |
| 持续运行 | 短时突发 | ✅ 轮次式 |
| 复杂实现 | 简单实现 | ✅ 可维护性 |

**结论**: 动态数组更适合我们的场景！

---

## 运行测试

### 单独运行
```bash
swift test --filter SpeechSessionMiddlewareClientASRTests
```

### 运行特定测试
```bash
swift test --filter clientASRSuccessWithinTimeout
```

### 查看详细日志
```bash
swift test --filter SpeechSessionMiddlewareClientASRTests --verbose
```

---

## 测试结果

```
✔ Test clientASRSuccessWithinTimeout() passed after 0.515 seconds.
✔ Test clientASRTimeoutFallsBackToNil() passed after 0.944 seconds.
✔ Test clientASRNotAvailableFallsBackToNil() passed after 0.117 seconds.
✔ Test pcmBufferCapturesDuringTurn() passed after 0.117 seconds.
✔ Test pcmBufferClearsAfterTurn() passed after 0.224 seconds.
✔ Test pcmNotBufferedOutsideSpeechTurn() passed after 0.117 seconds.
✔ Test telemetryEventsEmittedCorrectly() passed after 0.434 seconds.

✔ Suite "SpeechSessionMiddleware Client ASR" passed after 0.944 seconds.
✔ Test run with 7 tests in 1 suite passed after 0.945 seconds.
```

**所有测试通过！ 🎉**

---

## 下一步

### 集成测试
- [ ] 真实设备上运行
- [ ] 使用真实的 Speech Recognition API
- [ ] 连接真实后端

### 性能测试
- [ ] 压测：100 轮连续语音
- [ ] 内存泄漏检测
- [ ] 延迟 P95/P99 测量

### 跨端联调
参见：`CLIENT_ASR_INTEGRATION_CHECKLIST.md`

---

Last Updated: 2026-09-01  
Status: All tests passing ✅
