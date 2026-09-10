# 边界模式从未到达音频路径 · 播放生命周期

**日期**：2026-09-11
**状态**：代码与测试已齐。门禁见 §6。
**触发**：真机会话（02:27 崩溃 + 「静默时间再长点」；02:33 同一处**再次**崩溃）
**关联**：backend `docs/49` · `docs/43_assistant_audio_never_played.md` · meta `77_` P0-1 / F11 / F12

## 1. 守住的不变量

1. **两轮之间的说话边界由模式决定，并且那个决定必须真的走到音频路径上。**
2. **排进播放节点的音频必须真的被播放；而播放只在图还在的时候发生。** 会话结束之后到达的帧没有地方可放，`play()` 也不会告诉你。

---

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

**hold 4s → 8s**：模式修好之前这个值根本没上过路，所以第一个真正的 tap-to-start 会话也是第一次有机会判断 hold 长短 —— 停下来想词仍然会被提交。`「说完了」` 始终可用，自动提交只是兜底。**真机已确认此项生效。**

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

### C：B 的修复不够 —— `engine.isRunning` 不是"能播"的判据

B 的修复（`f361650`）把 `try?` 换成 `catch` + `isRunning` 复查 + 返回值。**真机上同一处又崩了一次**，而且日志给出了决定性的两行：

```
[Tracker] timing_ai_first_chunk [ "sequence": "1", "prev_event": "ai_turn_end" ]
AVAudioPlayerNode.mm:658  Player@0x1237ea080: Engine is not running because it was
                          not explicitly started or may have stopped because of
                          an interruption. Cannot play yet!
[Tracker] timing_ai_first_chunk [ "sequence": "2", "prev_event": "ai_first_chunk" ]
*** Terminating ... 'player started when in a disconnected state'
```

**第一帧只是警告，第二帧才抛异常。** 这说明 `isRunning` 在守卫处返回了 **true**：

- `engine.start()` 会成功 —— 它重建一个最小图就够了，`isRunning` 随即为真；
- 但 `playerNode` 是挂在**旧图**上的。图被拆掉之后节点就是"disconnected"，而这正是异常原文里那个词。

**"disconnected" 描述的是节点的状态，不是引擎的状态。** B 的守卫问的是错的问题。

**教训**：`engine.start()` 成功 ≠ 节点有地方播放。AVAudioEngine 内部图的生命周期（会话去激活、系统打断、`stop()`）不是我们能从外部可靠预测的 —— 试图预测就是这次返工的原因。

### D：C 的修复也不够 —— 会崩在**全新会话的第一帧**

02:36 又一次，同一个位置。这一次日志的形状变了：

```
timing_ai_turn_end  turn-1  outcome ok
timing_ai_first_chunk  sequence 1  prev_event ai_turn_end  delta_ms 3.412
*** Terminating ... 'player started when in a disconnected state'
```

**没有 `AVAudioPlayerNode.mm:658` 那条警告了**，直接从 sequence 1 抛。而且这是个**全新会话**（turn-1，`waitingForEvaluation` 刚过），`stopCapture()` 从未被调用 —— 所以 C 的 `playbackRetired` **正确地没有触发**，`playerNode.engine === engine` 也通过了。节点挂着、引擎在跑，`play()` 还是抛。

把三次崩溃并排看，共同点就一个：**全部落在会话的第一帧音频上**。而那是 `playerAttached == false` 的唯一时刻 —— 也就是说，**attach、connect、play 三件事只在那一刻挤在同一个同步块里发生**。

`attachPlayerIfNeeded()` 是惰性的，被调用于第一帧到达时，而那一刻**引擎已经在跑了**（采集是活的）。往一张**运行中的 render graph** 里 attach + connect，然后在同一个 tick 里立刻 `play()` —— 连接尚未提交到渲染图，AVFoundation 看这个节点就是"没连上"。

**这是唯一能同时解释三次崩溃的假设**，也是前两轮修复都失效的原因：它们都在修"引擎/节点状态"，而真正的问题在**什么时候改图**。

---

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

### C：不再预测引擎状态，改为守住自己的生命周期事件

**采集与播放共用同一个 `AVAudioEngine`，所以结束会话必须同时退役两个方向。**

```swift
private var playbackRetired = false      // 默认 false：新引擎可播，行为同以前

// stopCapture()
playbackRetired = true
if playerAttached {
    playerNode.stop()
    engine.detach(playerNode)            // 与 attach 对称
    playerAttached = false               // 下一个会话对着一张真实存在的图重新挂载
}
if engine.isRunning { engine.stop() }

// startCapture() —— 引擎确实起来之后才清除
playbackRetired = false
```

`play(frame:)` 在最前面拒绝：

```swift
guard !playbackRetired else {
    continuation.yield(.failed("playback retired; dropped audio frame"))
    return
}
```

**关键点：判据是一个我们自己的、确定的事件（`stopCapture()` 调用过），不是一个需要向 AVFoundation 查询的状态。** 这正是 C 相对 B 的区别 —— B 问 AVFoundation「现在能播吗」，C 只回答「这个会话还在吗」。

`startPlaybackIfNeeded()` 里另加一道廉价校验，因为中途中止（打断、路由变化）也可能拆图：

```swift
guard playerNode.engine === engine else {   // playerAttached 是我们的缓存，这是事实
    continuation.yield(.failed("playback node is detached from the engine; dropped frame"))
    playerAttached = false
    return false
}
```

### D：整张图在 `engine.start()` 之前建好，运行期不再改

```swift
// startCapture()
attachPlayerIfNeeded()          // ← 播放节点在这里就位，而不是等到第一帧
if !engine.isRunning { try engine.start() }
```

**运行中的 render graph 不改动** —— 这是 D 的全部内容。图的构建（attach + connect）和图的启动（`start()`）合成一个有序序列，两者之间没有音频帧能插进来。

### D'：`play()` 包一层 ObjC 异常兜底

前三轮都在**预测** `play()` 什么时候会抛。`play()` 抛的是 `NSException`，Swift 捕不到 —— 要接住它只能在 ObjC 层。新增 `FluentWorkObjCSupport` target（整个 target 只有这一件事）：

```objc
BOOL FWTryCatch(NS_NOESCAPE void (^block)(void), NSError **error);
```

```swift
var raised: NSError?
guard FWTryCatch({ self.playerNode.play() }, &raised) else {
    continuation.yield(.failed("player start raised: \(raised?.localizedDescription ?? "unknown")"))
    return false
}
```

于是"节点无处可播"这个我们读不到的状态，从**一次崩溃**变成**一条日志 + 丢掉那一帧**。上面的前置校验把窗口收窄；这一层让窗口是否收窄变得不重要。

---

## 4. 新方案理由

- **不靠 `engine.isRunning`**：C 的日志已经证明它会撒谎 —— 引擎可以"在运行"而节点无处可播。
- **`stopCapture()` 里 detach 而不是只置标志**：`playerAttached` 是缓存信念；图被拆掉后它还在说"已挂载"，下一轮就不会重新 attach。detach + 置 false 让标志与事实对齐，并且与 `attachPlayerIfNeeded()` 对称。
- **`playbackRetired` 默认 false**：既有的三个播放测试（`play` 独立于采集）保持不变；只有真的走过 `stopCapture()` 的会话才退役。语义上说得通 —— 新建的引擎是可用的。
- **`startEngineForPlayback` 做成可注入**：「引擎起不来」这条分支在健康设备上无法自然触发，而它恰恰是会终止 app 的那条 —— 和 `requestMicrophonePermission` / `sessionManager` / `decoder` 同一个理由。注意 **macOS 上 `play()` 在停掉的引擎上是静默无操作，只有 iOS 抛异常**，所以这个分支不可能靠开发机跑出来。
- **`forMode` 而不是再写一遍三元表达式**：重复的映射就是这次 bug 本身。

---

## 5. 影响面

- **轮次边界**：tap-to-start 现在真的是 tap-to-start —— 8s 停顿才自动提交，能量不再自己起轮。**真机已验证。**
- **播放生命周期**：会话结束后到达的音频帧被拒绝并上报 `.failed`，不再终止 app。下一个会话重新挂载播放节点。
- **协议 / 状态机**：零改动。
- **风险**：`stopCapture()` 之后引擎可能被播放路径重新拉起（无 tap，不采集），`deinit` 会停掉。

---

## 6. 门禁

```bash
swift test                      # 421/421
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试（先红后绿，失败输出粘贴自真实运行）：

| 测试 | 守住的不变量 | 修复前 |
|---|---|---|
| `liveAudioEngineStartCaptureKeepsTheConfiguredBoundaryMode` | `startCapture()` 之后 tracker 仍是会话配置的模式 | `(autoStart → true) == false` / `(silenceHold → 1.5s) == 4.0s` |
| `liveAudioEngineDoesNotStartPlaybackOnAStoppedEngine` | 引擎起不来时不启动播放节点，并上报 `.failed` | `expected the dropped frame to surface as .failed, got nil` |
| `liveAudioEngineRetiresPlaybackWhenCaptureStops` | 会话结束后到达的帧不启动播放节点，并上报 `.failed` | `Expectation failed: await engine._testPlaybackStarted() == false` |
| `objcExceptionCatcherTurnsARaiseIntoAnError` | ObjC 异常被转成 `NSError` 而不是终止进程 —— 播放路径的兜底依赖它 | 新 API，随 D′ 一起落地 |
| `objcExceptionCatcherReportsSuccessWhenNothingRaises` | 不抛时如实返回 `YES`，不吞掉正常路径 | 同上 |

第三个测试是把 `LiveAudioEngine.swift` 临时还原到 HEAD 跑出来的 —— 它复现的正是真机第二次崩溃：`stopCapture()` 之后 `play()` 仍然启动节点。

既有测试 `audioSpeechActivityTrackerTapToStartToleratesAThinkingPause` 里写死的 `4200ms` 改为从 `tapToStartSilenceHold` 推导 —— 它断言的是「接近 hold 的停顿不提交」，不是「hold 等于某个字面量」。

---

## 7. 本票不做

- ~~不加 ObjC 异常兜底~~：**原计划"第三次崩再做"，第三次真的崩了，已做**（§3 D′）。这条预判本身值得记下来 —— 三轮里前两轮都在赌"这次预测对了"，而兜底从一开始就能把赌注取消。
- **不重构播放与采集分属两个 AVAudioEngine**：那是消除整类问题的根治方案（两套图，播放的生死与采集无关），但会改变 `interruptNow()` 的 barge-in 时序，需要单独一张票。
- **不验 AEC**：见 meta `77_` §3.3 的受控实验。
- **不做真流式**：音频仍在轮末一次性到达。见 meta `77_` **P1-2**。
- **不改半双工兜底**：barge-in 仍依赖全双工。
