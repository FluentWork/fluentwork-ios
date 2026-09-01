# I12 LiveAudioEngine 解码器抽象 & B13 接入踩坑说明

## 背景

`I12` 主 PR（#27）合并了真实 `LiveAudioEngine` 的采集 / 输入 tap / 播放门 / 中断时间戳骨架，但**没有**把 `OpusPayload → PCM` 这层解码边界抽出来。`B13` 一旦要把火山 SDK 的 `VolcengineOpusDecoder` 装进去，要么改 `play(frame:)` 内部签名，要么把"这帧帧数据能不能解码"和"engine 调度"耦合死。

所以这次补的 i12 follow-up 干三件事：

1. 抽 `WSAudioFrameDecoder` 协议，让 `LiveAudioEngine` 不再假设 `opusPayload` 已经是 PCM16
2. 给两条路径各写一个实现：`RawPCM16FrameDecoder`（loopback / B13 上线前的回退）、`VolcengineOpusFrameDecoder`（显式 stub，B13 接入时直接换实现）
3. 把 DI 工厂 `wsAudioFrameDecoder` 接到 `audioEngine` 上

但这版实现撞上了 4 个**测试期才暴露**的坑，全是 AVFoundation + Swift Testing 边界问题，记下来避免下个接力的人再踩一遍。

## 这次踩到的坑

### 1. `await playerNode.scheduleBuffer(...)` 会永久挂起

错误方向：

```swift
// 在 actor `play(frame:)` 内部
await playerNode.scheduleBuffer(buffer, at: nil, options: [])
```

这是 `AVAudioPlayerNode.scheduleBuffer` 的 **async 重载**——它会**等到 buffer 被运行中的 engine 真正消费（播放完）才返回**。在生产路径里 `engine` 由 `startCapture()` 启动，buffer 进队后会被消费，没问题。

但只要写一个**只测门 / 解码路径、不调用 `startCapture()`** 的单元测试，engine 就从来没启动，buffer 永远不被消费，`await scheduleBuffer` 永不返回，整个测试用例 hang 死，`swift test` 进程也跟着挂死——这正是 `liveAudioEnginePlayRoutesThroughDecoder` / `liveAudioEnginePlaySkipsFramesAtOrBelowInterruptWatermark` 复现的症状。

正确方向：

```swift
// 使用 callback-based 重载，立即入队立即返回
playerNode.scheduleBuffer(buffer, at: nil, options: []) {}
```

辅以三件事确保后续不再翻车：

1. 在注释里写明**为什么**不能用 async 版本（"the async overload blocks until the buffer is consumed by the running engine"）
2. 配套测试 `consumeFirstEvent` 用 `withTaskGroup` + `Task.sleep` 在 N ms 内强制收尾，保证即使异步路径出问题也不会让 `swift test` 永远等
3. 任何 `await` 的 AVFoundation API 落到 actor 方法里前，先想清楚：**它在等什么？谁负责触发触发条件？**

### 2. `AVAudioConverter` 真实 drift 是 ~7.5%，5% 容差太严

错误方向：

```swift
// 4410 帧 44.1 kHz stereo float32 → 16 kHz mono PCM16
let expectedSampleCount = Int(Double(frameCount) * 16_000.0 / sourceSampleRate)  // 1600
let actualSampleCount = pcm.count / 2
let drift = Double(abs(actualSampleCount - expectedSampleCount)) / Double(expectedSampleCount)
#expect(drift < 0.05, ...)
```

实测 `AVAudioConverter` 在 4_410 帧这种**短 buffer** 上产出 1480 个样本，drift 7.5%。5% 容差必然挂。

注意：drift 不只是"误差"——`AVAudioConverter` 的 resampler 在 buffer 起止会保留若干样本的"历史 / 预热"区间，输出样本数严格不保证等于输入 × 比率。

正确方向：

1. 容差放到 **10%**（实测 7.5% + 余量），并在注释里写明实测值
2. 更稳健的检查是**按持续时间**而不是按样本数：
   ```swift
   let expectedDuration = Double(frameCount) / sourceSampleRate
   let actualDuration = Double(actualSampleCount) / 16_000.0
   #expect(abs(actualDuration - expectedDuration) / expectedDuration < 0.01)
   ```
3. 顺手校验 `mean(abs(samples)) > 1`，确认重采样后信号能量仍然非零（防止 converter 把所有样本填 0 而测试通过）

### 3. `swift test --num-workers 1` 必须搭配 `--parallel`

错误方向：

```bash
swift test --filter LiveAudioEngineTests --num-workers 1 2>&1 &
```

报错：

```
error: --num-workers must be used with --parallel
```

SwiftPM 的语义是 `--num-workers` 控制**已经并行运行**的 worker 数，所以必须显式开启 `--parallel`：

正确方向：

```bash
swift test --filter LiveAudioEngineTests --parallel --num-workers 1
```

或干脆不限制——本地调试时并行跑能更快暴露像 scheduleBuffer 这种 actor 隔离问题。

### 4. 测试 hang 死后 `swiftpm-testing-helper` 会留僵尸

`swift test` 一旦 hang 死，被它拉起的 `swiftpm-testing-helper` 子进程**不会自动清理**，还会抱住 `.build` 目录锁。下一次再跑 `swift test` 会卡在：

```
Another instance of SwiftPM (PID: xxxxx) is already running using
'/path/.build', waiting until that process has finished execution...
```

正确方向：

```bash
pkill -9 -f swift-package
pkill -9 -f swiftpm
pkill -9 -f swift-test
pkill -9 -f swift-build
sleep 2
ps aux | grep -E "swift" | grep -v grep | wc -l  # 应该是 0
```

以及**永远别让测试进程在没有 timeout 的情况下后台跑**——`swift test ... &` 后必须用 `kill -0 $PID` 循环检测 + `kill -9` 兜底，不然你下一次开工面对的是锁死的 `.build`。

## 这次 i12 补的内容落点

1. `Shared/FluentWorkCore/Dependencies/AppDependencies.swift`
   - `WSAudioFrameDecoder` 协议
   - `RawPCM16FrameDecoder`（loopback 用，校验偶数 byte 长度）
   - `VolcengineOpusFrameDecoder`（显式 `notAvailable` stub，B13 直接替换 `.decode` 实现）
   - DI 工厂 `wsAudioFrameDecoder` 接到 `audioEngine()` 上
2. `Shared/FluentWorkCore/Services/LiveAudioEngine.swift`
   - 注入 `decoder`，`init(decoder:)` 提供 `RawPCM16FrameDecoder()` 默认值
   - `play(frame:)` 走 decode → attach player → schedule buffer 完整链路
   - `interruptNow()` 记录 `ContinuousClock.Instant` 用于 barge-in 200 ms 预算断言
   - `_testConvertToPCM16(_:from:)` test-only hook，避免测试依赖硬件
3. `Tests/FluentWorkCoreTests/Audio/LiveAudioEngineTests.swift`
   - 8 个用例覆盖：解码器 round-trip / 奇数字节拒绝 / Opus stub not-available、engine 解码路由 / 解码失败事件 / 中断时间戳预算 / tap 链格式 / 播放门与中断水位

## 验收口径回顾（对照 I22 关闭记录）

- ✅ `PlaceholderAudioEngine` 从 DI 移除（保留为 XCTest 路径 fallback）
- ✅ 打断目标 ≤ 200 ms：`liveAudioEngineInterruptRecordsTimestampWithinLatencyBudget` 直接断言
- ✅ 音频参数对齐火山：16 kHz / mono / interleaved PCM16，由 `liveAudioEngineTapChainProduces16kMonoPCM16` 覆盖
- ✅ 不修改 `SpeechSession` 状态机：`SpeakingRoomFeature` / `SpeechSessionMiddleware` 没动
- ✅ View 不直接依赖 audio 底层：所有接线都走 `container.audioEngine()`（`AudioEngineProtocol`）
- ⏳ 真实 Opus 编码：等 B13 接入 `VolcengineOpusFrameDecoder` 真实现

## B13 接入 checklist

`VolcengineOpusFrameDecoder` 当前是 stub，后续接入需要：

1. 火山 SDK 选定并加入 `Package.swift` 后，把 `.decode(_:)` 改成 SDK wrapper 调用
2. 替换 DI 工厂：`wsAudioFrameDecoder` 默认值从 `RawPCM16FrameDecoder()` 换成 `VolcengineOpusFrameDecoder()`（或在容器层做 feature flag）
3. 用真链路（iPhone 17 Pro + 后端 B13）跑 `docs/06_第一波iPhone17Pro_Smoke_Runbook.md` 走一遍，确认首响 P90 ≤ 1.5s
4. 移除 `RawPCM16FrameDecoder` 中的"测试 fallback"备注，或者保留为 XCTest 专用 decoder
