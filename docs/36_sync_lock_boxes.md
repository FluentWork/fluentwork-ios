# 同步锁盒子：OSAllocatedUnfairLock 与并发覆盖

**票**：把语音 / bootstrap / DailyRead 中间件里的 `NSLock` 换成 `OSAllocatedUnfairLock`，并按真实双写路径补并发测试。  
**状态**：代码与测试已齐；公开 API 仍是同步的。  
**关联**：不是把这些对象改成 actor。`Middleware` 闭包和 `TrackerClientProtocol.track` 都是同步合同。

## 1. 要守住的原理

这些盒子同时被两条线碰：

1. **同步 `Middleware` 闭包**（写）
2. **Sendable `.task` / 音频 loop**（读或写）

调用方必须立刻看到刚写入的值（`turn-N`、abort 后的 PCM 门、bootstrap 防重入）。actor 会把每次读写变成 `await`，时间戳和 turn count 会漂。因此用 Apple `OSAllocatedUnfairLock`（iOS 16+）包一小块 `State`，临界区只做赋值，不 `await`、不打 tracker。

同一模式已经用在 `TurnCountBox` / `SpeechCaptureGate`。本票把 `SpeechSessionTimingsRecorder` 和 DailyRead observer 收进同一条规则。

## 2. 根因

1. Recorder 注释写的是 UnfairLock，实现仍是 `NSLock` + 手工 `locked {}`。AGENTS 禁止 `NSLock` / `NSRecursiveLock`。
2. 已有测试大多是单线程顺序用例，盖不住「中间件写、音频 loop 读」的实际交错。
3. `ObserverStartedBox` 原先是 `isStarted()` 再 `markStarted()`，check-then-act 在并发下可以启动两个 observer。

## 3. 方案与文件

| 文件 | 职责 |
|---|---|
| `SpeechSessionTimingsRecorder.swift` | `State` + `OSAllocatedUnfairLock`；`tracker.track` 在 lock 外 |
| `SpeechSessionMiddleware.swift` | `TurnCountBox` / `SpeechCaptureGate` / `TurnTimeoutTracking` / `TTSStreamTrace` |
| `AppBootstrapMiddleware.swift` | `BootstrapLoadGate.tryBegin` |
| `DailyReadMiddleware.swift` | `ObserverStartedBox.tryMarkStarted`（原子 one-shot） |

不改 WSS、状态机、音频采集。盒子从 `private` 升到 `internal`，只为 `@testable` 能直接打并发，和既有 `TurnCountBox` 一样。

## 4. 为何不折进 actor / 串行 queue

- 同步 middleware 里不能 `await timings.mark(...)`，否则 `session_create` 的 `delta_ms` 不再等于这次 reduce 的时刻。
- `TurnCountBox.get()` 必须在 `sendSpeechBoundary` 前同步读到刚 `set` 的 count。
- `CapturingTracker` 已用 `DispatchQueue.sync` 满足同步 `track`；recorder 不必再套一层 queue。

## 5. 影响面

状态、协议、音频路径不变。Observer 从 check-then-act 改成 `tryMarkStarted()`，与 `BootstrapLoadGate.tryBegin` 同语义：并发只允许一个获胜者。

## 6. 测试

覆盖的是**代码位置上的真实交错**，不是抽象锁压力测试。

| 盒子 | 实际交错 | 断言 |
|---|---|---|
| `TurnCountBox` | middleware `set(count)` vs 音频 loop `get()+1` | 递增写入对读者单调；结束值为 64 |
| `SpeechCaptureGate` | 录音 abort vs PCM / trailing `speechEnded` | abort 后仍丢 PCM，直到下一次 `beginSpeech` |
| `TurnTimeoutTracking` | 70s task `arm` 双发；`ai.turn.end` vs timeout `disarm` | `arm` 只成功一次；disarm 竞态后 `!isArmed` |
| `TTSStreamTrace` | 传输 loop 记帧 vs `ai.tts.start` `reset` | 32 次 `recordAudio` 计数为 32 |
| `SpeechSessionTimingsRecorder` | `setLogID` 后音频 `mark`；多 turn 的 start/end；重复 `markTurnEnded` | 后续 mark 带 `log_id`；各 turn 自己的 duration；第二次 end 为 `missing` |
| `BootstrapLoadGate` | `.appLaunched` 在 status 变成 `.loading` 前再次进入 | `tryBegin` 只成功一次；`end` 后可再 begin |
| `ObserverStartedBox` | 第一条 action 启动 observer | `tryMarkStarted` 只成功一次 |

已有 middleware 级回归 `repeatedAppLaunchDoesNotRestartBootstrapWhileLoading` 仍覆盖「loading 时第二次 dispatch」。

```bash
swift test --filter "turnCountBox|speechCaptureGate|turnTimeoutTracking|ttsStreamTrace|bootstrapLoadGate|observerStartedBox|speechSessionTimingsRecorder"
```
