# 边界模式从未到达音频路径

**日期**：2026-09-11
**状态**：代码与测试已齐。门禁见 §6。
**触发**：真机会话（2026-09-11 02:27）—— 「player started when in a disconnected state」崩溃 +「静默时间再长点」。
**关联**：backend `docs/49` · `docs/43_assistant_audio_never_played.md` · meta `77_` P0-1

## 1. 守住的不变量

**两轮之间的说话边界由模式决定，并且那个决定必须真的走到音频路径上。**

## 2. 根因

### A：`startCapture()` 把刚配好的模式换回默认值 —— 静音判定一直是 1.5s

上一张票（`41_`）把 tap-to-start 的 hold 提到 4s。**它从未生效过。** 调用顺序：

```
middleware .createSession
  await audioEngine.setSpeechBoundaryMode(.tapToStart)   // → autoStart=false, 4000ms
  try await audioEngine.startCapture()                   // → speechTracker = AudioSpeechActivityTracker()
```

`AudioSpeechActivityTracker()` 用**默认参数**：`autoStart: true`、`silenceHold: 1500ms`。于是每一个会话都跑在 auto-VAD 配置上：

- **1.5s 静音就提交一轮** —— 用户说「我记得有一个认为静默1.5s后认为说话结束的」。是的，就是 1.5s。
- **能量还能自己开启一轮**（`autoStart: true`）—— 环境噪音可以凭空起一轮。

复现输出（先红）：

```
✘ Expectation failed: (tracker.autoStart → true) == false
  ↳ tap-to-start must not let energy open a turn
✘ Expectation failed: (tracker.silenceHold → 1.5 seconds) == (tapToStartSilenceHold → 4.0 seconds)
  ↳ startCapture rebuilt the tracker with the 1.5 seconds auto-VAD hold
```

模式 → (`autoStart`, `silenceHold`) 的映射原本**内联在 `setSpeechBoundaryMode` 里**，而别处都从初始化器默认值构造 tracker —— 两套配置各说各话。现在收敛成 `AudioSpeechActivityTracker.forMode(_:)` 一处，`speechTracker` 的声明初值、`setSpeechBoundaryMode`、`startCapture` 全都走它。

### B：`playerNode.play()` 在停掉的引擎上抛 NSException —— 直接终止 app

`docs/43` 加了 `startPlaybackIfNeeded()`，它长这样：

```swift
if !engine.isRunning { try? engine.start() }
if !playerNode.isPlaying { playerNode.play() }
```

`try?` 恰好吞掉了**唯一**能让下一行致命的失败。而 `AVAudioPlayerNode.play()` **不抛错** —— 它抛的是未捕获的 `NSException`：

```
*** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio',
    reason: 'player started when in a disconnected state'
```

触发路径是**会话拆除与在途音频的竞态**：`stopCapture()` 在 `endSession` 上跑（middleware `768` / `795`），会 `engine.stop()`；而 socket 里还有在途帧。`cancel(id: transportEvents)` 是异步的，下一帧到达时引擎已经停了 —— 进程就没了。

日志上的形状很明确：`ai.turn.end` → `ai.text.delta` → `ai_first_chunk` **sequence 1** → 崩溃。第一帧。

## 3. 方案

### A：模式是唯一来源

```swift
static func forMode(_ mode: SpeechBoundaryMode) -> AudioSpeechActivityTracker {
    AudioSpeechActivityTracker(
        silenceHold: mode == .tapToStart ? tapToStartSilenceHold : autoVADSilenceHold,
        autoStart: mode == .autoVAD
    )
}
```

`startCapture()` 改为 `speechTracker = .forMode(speechBoundaryMode)`。`setSpeechBoundaryMode` 也改成整体替换 —— `forMode` 返回的 tracker 本来就没有在途语音，等价于原来那次 `discard()`，但少一份重复。

顺带修掉声明初值的不一致：`speechTracker` 原本以 `AudioSpeechActivityTracker()`（`autoStart: true`）起手，而 `speechBoundaryMode` 默认是 `.manual`。现在两者都从 `.manual` 出发。

**hold 4s → 8s**：模式修好之前这个值根本没上过路，所以第一个真正的 tap-to-start 会话也是第一次有机会判断 hold 长短 —— 停下来想词仍然会被提交。`「说完了」` 始终可用，自动提交只是兜底。

### B：`play()` 之前必须确认引擎在跑

```swift
private func startPlaybackIfNeeded() -> Bool {
    attachPlayerIfNeeded()
    if !engine.isRunning {
        do { try startEngineForPlayback(engine) } catch {
            continuation.yield(.failed("playback engine did not start: ..."))
            return false
        }
    }
    guard engine.isRunning else {
        continuation.yield(.failed("playback engine is not running; dropped frame"))
        return false
    }
    if !playerNode.isPlaying { playerNode.play() }
    return true
}
```

三处要点：

- **`try?` 换成 `catch`**：失败不再是隐形的。
- **`isRunning` 复查不是冗余**：`start()` 可能正常返回但引擎并未运行，这一行是唯一挡住 `play()` 的东西。
- **返回值被 `play(frame:)` 消费**：`false` 时直接不排缓冲 —— 排在死节点上也没有意义。

## 4. 新方案理由

- **不在 `stopCapture()` 里加"已结束"标志**：那是把崩溃挡在门口，而引擎停掉的原因不止会话结束（打断、路由变化、启动失败）。`isRunning` 是所有这些的共同下游，挡在那里才完整。
- **`startEngineForPlayback` 做成可注入**：「引擎起不来」这条分支在健康设备上无法自然触发，而它恰恰是会终止 app 的那条 —— 和 `requestMicrophonePermission` / `sessionManager` / `decoder` 同一个理由。注意 macOS 上 `play()` 在停掉的引擎上是**静默无操作**，只有 iOS 抛异常，所以这个分支不可能靠开发机跑出来。
- **`forMode` 而不是再写一遍三元表达式**：重复的映射就是这次 bug 本身。

## 5. 影响面

- **轮次边界**：tap-to-start 现在真的是 tap-to-start —— 8s 停顿才自动提交，能量不再自己起轮。
- **崩溃**：会话拆除期间到达的音频帧不再终止 app，改为上报 `.failed`。
- **协议 / 状态机**：零改动。
- **风险**：`startPlaybackIfNeeded()` 会在播放路径上尝试 `engine.start()`；失败时只是丢帧并上报，不会更糟。`stopCapture()` 之后引擎可能被播放路径重新拉起（无 tap，不采集），`deinit` 会停掉。

## 6. 门禁

```bash
swift test                      # 418/418
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试（先红后绿，失败输出粘贴自真实运行）：

| 测试 | 守住的不变量 | 修复前 |
|---|---|---|
| `liveAudioEngineStartCaptureKeepsTheConfiguredBoundaryMode` | `startCapture()` 之后 tracker 仍是会话配置的模式 | `(autoStart → true) == false` / `(silenceHold → 1.5s) == 4.0s` |
| `liveAudioEngineDoesNotStartPlaybackOnAStoppedEngine` | 引擎起不来时不启动播放节点，并上报 `.failed` | `expected the dropped frame to surface as .failed, got nil` |

为了让后者可断言，新增 `startEngineForPlayback` 注入点与 `_testEngineRunning()` 钩子。

既有测试 `audioSpeechActivityTrackerTapToStartToleratesAThinkingPause` 里写死的 `4200ms` 改为从 `tapToStartSilenceHold` 推导 —— 它断言的是「接近 hold 的停顿不提交」，不是「hold 等于某个字面量」。

## 7. 本票不做

- **不在会话结束后硬性拒绝播放**：`play(frame:)` 仍可脱离采集独立工作（三个既有测试依赖这一点）。往 socket 里塞帧的上游已经在 `endSession` 被取消。
- **不验 AEC**：见 meta `77_` §3.3 的受控实验。
- **不做真流式**：音频仍在轮末一次性到达。见 meta `77_` **P1-2**。
