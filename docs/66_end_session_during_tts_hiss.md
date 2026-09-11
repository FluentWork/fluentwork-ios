# 结束练习时 TTS 还在播：沙沙声

**日期**：2026-09-12
**状态**：代码与测试已齐。沙沙本身是扬声器现象，CI 钉的是拆图顺序与迟到帧不得 `.failed`；真机听感见 §7。
**触发**：TTS 正在播放时点「结束练习」，确认后喇叭里仍有沙沙声。

## 1. 守住的不变量

**拆会话音频图时，引擎必须先停，图才能动；已经排进播放节点的 PCM 必须被倒掉，不能从 `engine.stop()` 里漏出来。**

迟到的 TTS 帧（socket 还没关完）是预期，不是失败。对它们 yield `.failed` 会让进程级音频泵退出，下一场「开始说话」没人听。

## 2. 根因

`PlaybackTeardown` 先前只保证了 `stopPlayer → stopEngine → detachPlayer`。

结束练习的真实状态是三样同时在：采集 tap 装着、TTS 缓冲排在 player 上、engine 在跑。那条路径上还有两处会出沙沙：

1. **`inputNode.removeTap` 在 engine 还在跑时就执行。** 这和 `detach` 是同一类图突变。`detach` 会直接 `NSException`；`removeTap` 比较安静 —— 喇叭里一串静态噪声。
2. **`playerNode.stop()` 不清已排程的 buffer。** `engine.stop()` 时剩余 PCM 从半截里漏出来，听感就是沙沙，不是干净的切断。

同一条路径上还有一个会把下一场弄死的信号错误：

3. **`play(frame:)` 在 `playbackRetired` 之后 yield `.failed("playback retired; dropped audio frame")`。** 音频泵把 `.failed` 当成致命并 `return nil`（`docs/49`）。TTS 还在路上时点结束练习，迟到帧会杀掉整场进程里的泵。旧测试 `liveAudioEngineRetiresPlaybackWhenCaptureStops` 曾经把「yield `.failed`」当成「帧被丢掉了」的证据，所以这个错误信号一直是绿的。

没有给 `endTap` 加 `.stopPlayback`。那条 effect 是 barge-in 用的：`interruptNow()` 停掉当前播放，但**更高序号的 TTS 帧仍会把 player 重新 `play()` 起来**。会话结束如果走这条，会先停、再被迟到帧唤醒、再被 `stopCapture` 拆掉 —— 比沙沙更吵。会话结束只走 `stopCapture`，并把「倒掉队列 / 先停引擎再动图」收进拆图顺序里。

## 3. 修法

`PlaybackTeardown` 在「结束练习 + TTS 还在播」这条路径上的顺序是：

```
stopPlayer → resetPlayer → stopEngine → removeTap → detachPlayer
```

`stopCapture()` 把 `playbackRetired = true` 放到循环之前，迟到帧在解码之前就被丢掉。丢掉时不再 yield `.failed`。

`interruptNow()` 在 `stop()` 之后加了 `reset()`，所以 barge-in 也不会把上一轮的尾巴漏进用户开口。

## 4. 测试

三个守卫，都在 `LiveAudioEngineTests.swift`。

| 测试 | 钉什么 |
|---|---|
| `teardownNeverMutatesTheGraphWhileTheEngineIsRunning` | 采集 tap + 正在播的 player + 运行中的 engine：顺序必须是上面那条 |
| `teardownStopsARunningEngineEvenWithNoPlayer` | 缺 player / 缺 tap / 都没有时的退化顺序，含 `resetPlayer` |
| `stopCaptureDropsLateFramesWithoutFailingTheEngine` | `stopCapture` 之后的帧不到达解码器，也不发 `.failed` |
| `liveAudioEngineRetiresPlaybackWhenCaptureStops` | 迟到帧不得把已拆掉的 player 再 `play()` 起来。原先还要求 yield `.failed`，那个契约已作废 |

### 修复前的实际失败输出

```
✘ Test teardownNeverMutatesTheGraphWhileTheEngineIsRunning() recorded an issue at LiveAudioEngineTests.swift:1101:5:
  Expectation failed: (steps → [stopPlayer, stopEngine, detachPlayer])
  == ([.stopPlayer, .resetPlayer, .stopEngine, .removeTap, .detachPlayer])
± removed [resetPlayer, removeTap]
↳ got [stopPlayer, stopEngine, detachPlayer]
✘ … (removeTap → nil) != nil
  ↳ an installed tap is a graph mutation, same family as detach
✘ … (resetPlayer → nil) != nil
  ↳ stop() without reset() leaves scheduled PCM to drain as static

✘ Test teardownStopsARunningEngineEvenWithNoPlayer() recorded an issue at LiveAudioEngineTests.swift:1145:5:
  Expectation failed: (… → [stopPlayer, detachPlayer]) == ([.stopPlayer, .resetPlayer, .detachPlayer])
± removed [resetPlayer]
✘ … (… → [stopEngine]) == ([.stopEngine, .removeTap])
± removed [removeTap]

✘ Test stopCaptureDropsLateFramesWithoutFailingTheEngine() recorded an issue at LiveAudioEngineTests.swift:1188:5:
  Expectation failed: (failure → .failed("playback retired; dropped audio frame")) == nil
  ↳ dropping a late frame must not fail the engine; got Optional(...failed("playback retired; dropped audio frame"))
```

### 守卫的守卫

把 `steps()` 改回「不 emit `resetPlayer` / `removeTap`」：红的是上面那两条 teardown 测试，失败信息仍是缺那两步。

把 `play(frame:)` 在 retired 时重新 yield `.failed`：红的是 `stopCaptureDropsLateFramesWithoutFailingTheEngine`，失败信息仍是那条 `.failed("playback retired; dropped audio frame")`。

## 5. 明确没做的

- 没有改「结束练习」确认框的弹出时机。点开确认框时 TTS 继续播；只有确认之后才拆图。取消应继续听。
- 没有把 `voiceProcessing` 打进 `firstWave`。那是另一条、要先过 `docs/62` T4 的票。
- 没有在 `endTap` 上发 `.stopPlayback`。原因见 §2。

## 6. 门禁

```
swift test --parallel --num-workers 1
# Test run with 532 tests in 21 suites passed

xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'generic/platform=iOS' build
# BUILD SUCCEEDED
```

## 7. 真机判据

TTS 正在播放时点「结束练习」并确认：喇叭应立刻静音，没有沙沙、没有半截音节漏出来。再进房间，「开始说话」仍能打开一轮。
