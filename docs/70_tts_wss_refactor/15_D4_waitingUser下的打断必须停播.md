# 15 — 实现说明：`.waitingUser` 下的 barge-in 必须停播

> 对应缺陷：`10_事实基线与缺陷清单.md` **D4**（🟠【读码】）。
> 改动：`SpeechSessionMachine.swift` 一条合并 arm 拆成两条 + 三条新测试。
> **本改动落在高风险区**（`AGENTS.md` 的 High-Risk Paths 第 2 条：SpeechSession 状态机），影响面见 §5。

## 1. 这条改动守的是什么契约

**「用户开口时，上一轮的 AI 声音必须停」这条契约，覆盖每一条用户开口的路径，而不只是相位恰好等于 `.aiSpeaking` 的那条。**

这条契约不是本次发明的，它写在代码自己的注释里。`.processing/.evaluation` 的 `evaluationTimedOut` arm 交代了为什么那里**不**停播：

> Nothing needs the timer for silence. A badge that arrives in time lands in this same phase without stopping playback, and **barge-in stops it on both paths that mean it — from `.aiSpeaking` and from this phase**, both via `vadSpeechStart` / `holdStart`.
> （`SpeechSessionMachine.swift:96-99`，改动前）

这句话把「谁负责停播」交了出去：定时器不管，因为**打断会管**。它列了两条路径——`.aiSpeaking` 与 `.processing`。而实际存在**三条**：`.waitingUser` 是第三条，它不停。

于是契约在代码里是「三段论少了一项」：前提（打断负责停播）成立，承诺（覆盖所有路径）不成立。

## 2. 根因：一条 arm 被两个前提不同的相位共用

改动前，三个入口共用同一条 arm：

```swift
// 改动前（SpeechSessionMachine.swift:126-132）
case (.waitingUser, .vadSpeechStart), (.waitingUser, .holdStart),
     (.processing, .vadSpeechStart) where state.processingStage == .aiAnswer,
     (.processing, .holdStart) where state.processingStage == .aiAnswer:
    state.phase = .recording
    state.processingStage = nil          // ← 一个 effect 都不发
```

注释给出的理由是「nothing is playing, so nothing needs stopping」。**这句话对 `aiAnswer` 成立，对 `.waitingUser` 不成立。**

### 2.1 `.waitingUser` 确实可能还有声音在播

`.waitingUser` 有五个入口，其中三个都可能在音频未播完时进入：

| 入口 | 位置 | 此时音频状态 |
|---|---|---|
| `(.aiSpeaking, .aiTurnEnd)`，`userTurnCount == 0`（greeting / 首轮） | `:75-79` | **整轮音频已到达、正排在播放器里** |
| `(.processing, .evaluationReceived)` | `:81-83` | 同上——徽章到达与音频无关 |
| `(.processing, .evaluationTimedOut)` | `:85-101` | 同上，且该 arm 的注释**明确选择不停播** |
| `(.recording, .networkLost)` | `:213-217` | 无 |
| `(_, .systemInterruptEnded)`（default 分支） | `:272-283` | 无 |

第二条与第三条是关键：**TTS 音频是 burst 到达的**（`14_` §5 引用的真机数据：276 帧 / 27.6 秒的音频在 88ms 内全部送达），到达之后由播放器按实时速度慢慢播。所以「`ai.turn.end` 已到」与「声音已播完」是两件毫不相干的事——`evaluationTimedOut` 那条注释自己把这一点说透了：

> the timer and the audio are unrelated clocks.

### 2.2 pump 帮不上忙

`audioEventPump` 的 barge-in 分支判定是 `phaseBox.get() == .aiSpeaking`（`SpeechSessionMiddleware.swift:470`）。`.waitingUser` **不满足**，所以那条路径连 `control.interrupt` 都不会发——这同时解释了为什么 D3 的修法（把 interrupt 从状态机挪给 pump）在这里没有替代方案：pump 根本没进这个分支。

**这是 D4 与 D3 的区别**：D3 是「同一个决定被两处做」，D4 是「这个决定没有任何一处做」。所以 D4 只能由状态机发，且只能发 `.stopPlayback`（理由见 §4）。

### 2.3 这是被记录过两次、但一直没修的问题

- `08_真机验证记录_2026-09-20.md` §5.1：**「若 badge 命中、阶段已推进到 `.waitingUser`，而回复音频还在播，此时打断不会停播。500ms 的提示音看不出来，5 秒就能暴露。属于状态机（高风险区），建议单独立项。」**
- `10_事实基线与缺陷清单.md` D4（🟠，【读码】）。

两次都判断正确，两次都没落地。**「500ms 的提示音看不出来」是这个缺陷能活下来的原因**：日常练习里 AI 回复短、音频短，残留窗口小到听不出来。

## 3. 改法与被谁拥有

**按「有没有东西可停」拆成两条 arm，让这件事变成结构性事实：**

```swift
// `.waitingUser`：可能有声音 → 停播
case (.waitingUser, .vadSpeechStart), (.waitingUser, .holdStart):
    state.phase = .recording
    state.processingStage = nil
    effects.append(.stopPlayback)

// `aiAnswer`：没有东西可停 → 一个 effect 都不发（理由见 §4）
case (.processing, .vadSpeechStart) where state.processingStage == .aiAnswer,
     (.processing, .holdStart) where state.processingStage == .aiAnswer:
    state.phase = .recording
    state.processingStage = nil
```

只加了一个 effect，没有新事件、没有新副作用、没有新类型、没有新相位。

| 文件 | 改了什么 |
|---|---|
| `Shared/FluentWorkCore/SpeechSession/SpeechSessionMachine.swift` | `.waitingUser` 与 `aiAnswer` 从一条合并 arm 拆成两条；`.waitingUser` 那条加 `.stopPlayback` |
| `Tests/FluentWorkCoreTests/SpeechSession/SpeechSessionMachineTests.swift` | 新增 `vadFromWaitingUserStopsLeftoverPlayback`、`abortLandingPadHasNothingLeftToStop` |
| `Tests/FluentWorkCoreTests/Architecture/SpeakingRoomSessionWiringTests.swift` | 新增 `bargeInFromWaitingUserStopsLeftoverPlayback`（走真实 pump 与真实协调器） |

## 4. 为什么是「只停播」，为什么 `aiAnswer` 不动

### 4.1 不发 `.sendInterrupt`

`.sendInterrupt` 的含义是「告诉网关停掉这一轮的 TTS 流」。而能走到 `.waitingUser` 的路径上，**`ai.turn.end` 都已经到了**——服务端那一轮已经结束，没有可打断的流。剩下的是**已到达客户端、排在播放器里的音频**，那是本地的事，网关不掌握。

这与 `.processing/.evaluation` 那条 arm 的政策一致（`:161-166`，同样只有 `.stopPlayback`）。两条 arm 现在对同一件事给出同一个答案，不是巧合，是同一个前提。

### 4.2 `.stopPlayback` 在没有活跃轮次时也有效

这是本次能成立的关键事实，从代码读到：`TTSPlaybackCoordinator.onInterrupt(turnID:)`（`TTSPlaybackCoordinator.swift:103-108`）只在 `turnID` 非空时写 `turnRegistry[turnID] = .superseded`，而 `await sink.interruptNow()` 是**无条件**调用的。所以即便 `ai.turn.end` 已经把这一轮结束掉、`currentTurnID()` 返回 `nil`，`.stopPlayback` 仍然会清空播放器里排着的缓冲。

中间件的解释器（`SpeechSessionMiddleware.swift:1253-1264`）与这一点一致：

```swift
case .stopPlayback:
    return .fireAndForget {
        let turnID = await ttsCoordinator.currentTurnID()
        await ttsCoordinator.onInterrupt(turnID: turnID)
        container.tracker().track(event: "tts_interrupt", properties: ["turn_id": turnID ?? "nil"])
    }
```

**没有活跃轮次时，这个 effect 是「清空播放器 + 记一条 `turn_id: nil`」——有用，且无害。**

### 4.3 `aiAnswer` 为什么必须留在另一条 arm

`aiAnswer` 是 I21 的 abort 落点（用户录满 60 秒）。它确实没有东西可停，两条独立理由：

1. **它只有一条来路**：`(.recording, .recordingTimedOut)`（`:174-187`），且 `state.processingStage = .aiAnswer` 在全仓**只有这一个写入点**（`:187`）。而 `.recording` 只从「可能有声在播」的相位进入，那些入口全都带 `.stopPlayback`（`.aiSpeaking` 两条、`.waitingUser` 两条、`.processing/.evaluation` 两条）——上一轮的声音已经清过。
2. **本轮的声音还没到**：停在 `aiAnswer` 意味着这一轮的首块音频尚未到达——若到了，`(.processing, .aiFirstAudioChunk)` 会把它升到 `.aiSpeaking`（`:234-236`）。

`SpeechSessionState.discardsTurnOnReconnect`（`SpeechSessionState.swift:257`）用的是同一个判断：`processingStage != .aiAnswer` 才丢弃在途轮次。**「`aiAnswer` 里这一轮的答案还在路上」是代码里已经存在的共识**，本条 arm 只是不违背它。

**如果为省事把 `.stopPlayback` 加到整条合并 arm 上**，`aiAnswer` 路径会多一次空转的 `interruptNow()` + 一条 `tts_interrupt: nil` 埋点。功能上无害，但会把「谁需要停播」这件事重新搅浑——而 §2 的教训正是「两个前提不同的相位不能共用一条 arm」。`abortLandingPadHasNothingLeftToStop` 就是钉住这一点的测试。

## 5. 影响面（高风险区，逐条）

- **状态机**：**无新转换**。两条 arm 的相位变化与 `processingStage` 处理一字未动（`.waitingUser → .recording`、`.processing → .recording` 都已在 `isValidTransition` 白名单里，`:378-379`）。唯一变化是 `.waitingUser` 那条多一个 effect。
- **协议 / 线上**：**零变化**。不发新帧、不改帧数、不动 `control.interrupt`。D3 的「一次 barge-in 只发一次 interrupt」不受影响——本次加的是 `.stopPlayback`，不是 `.sendInterrupt`。
- **音频**：**这是目的本身**。`.waitingUser` 下用户开口时，播放器里排着的残留 TTS 现在会被清掉，不再与用户的话叠加。
- **埋点**：`.waitingUser` 的 barge-in 现在会多一条 `timing_playback_stop` + 一条 `tts_interrupt`（`turn_id` 通常为 `nil`，因为轮次已结束）。**这是新增的可观测信号**，也是真机验证的抓手（§8）。
- **`.aiSpeaking` / `.processing/.evaluation` 两条路径**：一字未动。
- **回滚**：`git revert` 该提交即可（两条 arm 合回一条）。

## 6. 测试

### 6.1 先红：改动前的失败输出（原文）

状态机层（`SpeechSessionMachineTests.swift`）：

```
✘ Test vadFromWaitingUserStopsLeftoverPlayback() recorded an issue at SpeechSessionMachineTests.swift:189:5: Expectation failed: effects.contains(.stopPlayback)
↳ effects.contains(.stopPlayback) → false
↳   effects → [FluentWorkCore.SpeechSessionSideEffect.trackTransition(from: FluentWorkCore.SpeechSessionPhase.waitingUser, to: FluentWorkCore.SpeechSessionPhase.recording, stage: nil)]
```

接线层（`SpeakingRoomSessionWiringTests.swift`，跑真实 pump + 真实协调器 + `StubAudioEngine`）：

```
✘ Test bargeInFromWaitingUserStopsLeftoverPlayback() recorded an issue at SpeakingRoomSessionWiringTests.swift:1102:5: Expectation failed: await audioEngine.snapshotInterruptCalls() == interruptsBefore + 1
↳ 用户从 .waitingUser 开口时没有停掉残留音频
```

状态机那条的输出本身就是根因的完整证明：**相位从 `.waitingUser` 走到 `.recording` 了，effects 里只有一个 `trackTransition`，没有任何东西碰播放器。**

### 6.2 新测试

| 测试 | 层 | 断言 |
|---|---|---|
| `vadFromWaitingUserStopsLeftoverPlayback` | 状态机 | `(.waitingUser, .vadSpeechStart)` → `.recording` 且含 `.stopPlayback`、不含 `.sendInterrupt` |
| `abortLandingPadHasNothingLeftToStop` | 状态机 | `(.processing/.aiAnswer, .vadSpeechStart)` → `.recording` 且**不含** `.stopPlayback` / `.sendInterrupt` |
| `bargeInFromWaitingUserStopsLeftoverPlayback` | 接线 | 真机形状：`ai.tts.start` + 一帧音频 → 播出一帧 → `ai.turn.end` → `.waitingUser` → `emit(.speechStarted)` → `interruptCalls` 恰好 +1 |

**为什么必须补一条接线级的**：状态机测试只能证明「effects 里有 `.stopPlayback`」，证明不了「这个 effect 真的清空了播放器」。而 §4.2 那个「`turnID` 为 nil 时 `interruptNow()` 仍被调用」是**跨文件的**事实（`SpeechSessionMiddleware` → `TTSPlaybackCoordinator` → `AudioEngine`），只有接线级的测试能钉住。这条测试的 fixture 刻意造出缺陷的**真机形状**——`ai.turn.end` 时 `userTurnCount == 0`，音频已播出但未播完。

### 6.3 一条被改对的测试断言（本次自己的错）

`abortLandingPadHasNothingLeftToStop` 第一版写的是 `#expect(effects.isEmpty)`，跑出来是红的，而当时**代码是对的**。原因是 `reduce` 在返回前会对每一次相位变化插入一条 `trackTransition`（`SpeechSessionMachine.swift:342-357`）：

```
✘ Test abortLandingPadHasNothingLeftToStop() recorded an issue at SpeechSessionMachineTests.swift:203:5: Expectation failed: effects.isEmpty
```

`effects` 从不「为空」，只要相位动过。断言改成「不含 `.stopPlayback` / `.sendInterrupt`」——**这才是这条测试真正想钉的东西**（「这条 arm 不该碰播放器」），`isEmpty` 只是它的一个过强且错误的替身。

记在这里是因为它值得记：**`effects.isEmpty` 在这个状态机里几乎总是一个错误的断言形式**，而同文件里 `recordingTimedOutFromWaitingUserIsNoOp`、`evaluationTimedOutFromWaitingUserIsNoOp` 用的是它——那两条之所以对，是因为它们的前提是「相位不变」。改相位又断言 `isEmpty`，一定红。

## 7. 顺带记录：全量测试里有一批 2 秒超时的既有 flaky

跑门禁时观察到全量 `swift test` 偶发失败，且**每次失败的测试都不同**：

| 轮次 | 失败测试 | 报错 |
|---|---|---|
| 1 | `continuingARoomPassesThePreviousSessionIDToTheClient` + `theFirstSessionOfAVisitContinuesFromWhereItWasOpened` | `TimeoutError()` |
| 2 | `forceCloseFromConnectingEndsSessionAndClosesTransport`（**未改动的 `bfc8fc2` 基线**） | `TimeoutError()` |

共同形状：都用了 `try await waitUntil(timeoutNanoseconds: 2_000_000_000)`，在**全量并行**下超时；单独跑 3 次全部 0.024s 通过。已确认与本次改动无关——两条失败测试都不派发任何 VAD 事件，且基线同样复现。

**这是既有问题，不在本次范围**，但值得单独立项：`waitUntil` 的 2 秒预算在满负载并行下不够，让门禁结果带随机性——而「门禁可不可信」本身比某一条测试更值钱。

## 8. 门禁

| 项 | 命令 | 结果 |
|---|---|---|
| `swift test` | `swift test --disable-sandbox` | **587 tests / 28 suites 全通过**（改动前 584；新增 3 条） |
| `FluentWorkHost` Debug build | `xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost -configuration Debug -destination 'generic/platform=iOS Simulator' build` | `** BUILD SUCCEEDED **` |
| 实现说明 | — | 本文，与代码和测试同一次提交 |

> **构建目标勘误**：本系列前几篇记的命令是对的（`generic/platform=iOS Simulator`），但本轮第一次误用了 `-destination 'platform=macOS'`。`FluentWorkHost` 在 `project.yml` 里是 `platform: iOS` / `deploymentTarget: "17.0"`，macOS destination 会让它去签真机描述文件并失败（`Provisioning profile ... doesn't include the currently selected device "Tango的Mac mini"`）。那是**调用错误，不是代码问题**。

**未做真机验证。** 本次改的是「用户开口时残留音频有没有被清掉」——一个**用耳朵就能判**的行为，也是 `08_` §5.1 当初发现它的方式。

单测已经钉住了机制（`interruptNow()` 被调用），但**「清干净了没有」只有真机能回答**：`interruptNow()` 清的是播放器缓冲，而 AVAudioEngine 的实际静音还涉及 `playerNode` 的状态（`LiveAudioEngine.swift:924` / `:955`）。建议下一轮真机验证与 D3 的残留窗口合并进行，用 `09_麦克风替身.md` 的 `FW_MOCK_MIC` 去掉真麦克风依赖，并**刻意用一条 5 秒以上的长回复**——`08_` §5.1 说得很准：500ms 的提示音看不出来，5 秒就能暴露。

验证抓手（新增的可观测信号，见 §5）：

```
timing_playback_stop            ← 用户开口时出现（改动前不出现）
tts_interrupt ["turn_id": "nil"] ← 轮次已结束，故为 nil
```
