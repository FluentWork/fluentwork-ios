# 14 — 实现说明：一次 barge-in 只发一次 `control.interrupt`

> 对应缺陷：`10_事实基线与缺陷清单.md` **D3**（🟠【读码】）。
> 改动：`SpeechSessionMachine.swift` 拆开一条 arm + 两条新测试 + 一条既有测试的改写。
> **本改动落在高风险区**（`AGENTS.md` 的 High-Risk Paths 第 2 条：SpeechSession 状态机），影响面见 §5。

## 1. 这条改动守的是什么契约

**一次 barge-in，只对网关说一次「停」，而且必须说在 `user.speech.start` 之前。**

两半都不可省，而且理由不同：

- **「一次」**——`submitTranscript("__interrupt__")` 不幂等：它做两件事，`transport.markInterrupted()`（武装传输层的丢弃水印）与 `send(control: .interrupt)`（`DefaultSpeechSessionClient.swift:139-144`）。调两次就重发一次帧、并把水印用同一个值重新武装，顺带触发 `BargeInAudioGate.markInterrupted()` 里的 `report.reset()`，**丢掉第一段丢弃运行的报告**。
  > **修订（2026-09-22，`18_`）**：它现在只做**一件**事——`transport.markInterrupted()` 与水印一起删了（`DefaultSpeechSessionClient.swift:139-148` 现在只有 `send(control: .interrupt)`）。本节「一次打断只发一次 `interrupt`」的结论**不受影响**，反而更干净：删掉的正是上面那句「顺带重新武装水印、丢掉第一段报告」。见 [`18_`](./18_删除传输层序号水印.md) §4.3。
- **「之前」**——`audioEventPump` 自己的注释写明了代价：
  > Sending start first is what made gateway delivered_chars: 0 on 2026-09-12 — start resets the previous turn's interrupt accounting.

  顺序错了，网关就把这次 interrupt 记到新一轮头上，上一轮的 TTS 不会被停。

改动前这两半只满足了一半。

## 2. 根因：同一个决定被两个地方做，而且两处的时序不同

`control.interrupt` 有两个触发点，都经 `submitTranscript("__interrupt__")`：

| # | 位置 | 时序 |
|---|---|---|
| 1 | `SpeechSessionMiddleware.swift:470-472`（`audioEventPump` 的 `.speechStarted`） | **在 `user.speech.start` 之前**（`:476-480`），`await` 过，顺序有保证 |
| 2 | `SpeechSessionMachine.swift:106`（`.aiSpeaking` barge-in 臂） | **在之后**——见下 |

第 2 处为什么必定晚于 start，是一条**结构性**事实，不是概率问题：

```
audioEventPump .speechStarted:
  :470  if phaseBox == .aiSpeaking → submitTranscript("__interrupt__")   ← 第 1 次（对）
  :476  await sendSpeechBoundary(started: true)                          ← user.speech.start
  :482  dispatch(.vadSpeechStart)                                        ← 状态机从这里才被叫醒
          → SpeechSessionMachine:106 → .sendInterrupt                    ← 第 2 次（晚）
```

而 `.vadSpeechStart` 在全仓**只有一个派发点**，就是 `:482`。所以第 2 处发出的 interrupt **永远**晚于 start——它从来达不到「打断上一轮」的目的，只会多一个被错记到新一轮上的帧，外加一次水印重新武装。

**这是「修在了一个调用点，没修另一个」**：2026-09-12 把顺序修在了 pump，状态机那一份留着没动。

## 3. 改法与被谁拥有

**把 `.aiSpeaking` 的那条 arm 按事件拆成两条**，让「谁该发」变成结构性事实：

```swift
case (.aiSpeaking, .vadSpeechStart):   // 只停本地播放
    effects.append(.stopPlayback)

case (.aiSpeaking, .holdStart):        // 停播放 + 发 interrupt
    effects.append(contentsOf: [.stopPlayback, .sendInterrupt])
```

理由不是「让测试变绿」，而是**顺序只能由 pump 保证**：

- pump 能保证，因为它 `await` 了那次发送；
- 状态机不能保证，因为 `.sendInterrupt` 是 `.fireAndForget`（`:1235-1238`），排不出顺序。

于是「谁发」由「谁能保证顺序」决定，而不是由「谁先想到」决定。

`.holdStart` 那条留着，因为它**不经 pump**，也没有配对的 `user.speech.start`——在那条路上，状态机的 interrupt 是唯一的一次。

| 文件 | 改了什么 |
|---|---|
| `Shared/FluentWorkCore/SpeechSession/SpeechSessionMachine.swift` | `.aiSpeaking` 的 arm 拆成 `vadSpeechStart` / `holdStart` 两条 |
| `Tests/FluentWorkCoreTests/SpeechSession/SpeechSessionMachineTests.swift` | 改写 `vadDuringAISpeakingTriggersInterruptSideEffects`；新增 `holdDuringAISpeakingStillSendsTheInterrupt` |
| `Tests/FluentWorkCoreTests/Architecture/SpeakingRoomSessionWiringTests.swift` | 新增 `bargeInFromTheVADPathSendsExactlyOneInterrupt`（走真实 pump） |

**没有新事件、没有新副作用、没有新类型。** `.sendInterrupt` 仍在，只是不再从 VAD 路径发出。

## 4. 为什么不是另外两条路

1. **反过来：删掉 pump 那次，让状态机独占。** 不行——状态机发出的必定晚于 start（§2），那正是要修的东西。
2. **保留两次，但让 `submitTranscript` 幂等。** 需要引入「这次 barge-in 已经发过了」的状态，而「一次 barge-in」本身没有标识（二进制帧没有 `turn_id`，这是 D2/Stage 3 的同一根轴）。用状态去补一个本可由结构消除的重复，是把简单问题换成复杂问题。
3. **给 `.vadSpeechStart` 加一个 `interrupted: Bool` 载荷。** 语义上更显式，但要改事件形状 + 全部派发点 + 测试。本次按最小改动取 arm 拆分，代价是「`.vadSpeechStart` 只来自 pump」这条不变量目前靠注释与单派发点维持（`Grep` 可验：全仓仅 `:482` 一处）。

## 5. 影响面（高风险区，逐条）

- **状态机**：**无新转换、无相位变化**。`(.aiSpeaking, .vadSpeechStart)` 仍然 `.aiSpeaking → .recording`，只是 effects 少一项。`(.aiSpeaking, .holdStart)` 一字未动。
- **协议 / 线上**：**barge-in 的 interrupt 帧从 2 帧变 1 帧**。这是本改动唯一的外部可见变化，也是目的本身。
- **音频**：无影响。`.stopPlayback` 在两条 arm 上都保留——本地停播与「告诉网关」是两件事，不能因为后者重复就把前者一起删。
- **水印**：不再被第二次 `markInterrupted()` 重新武装，`AudioDropReport` 的第一段丢弃运行报告因此不再被 `reset()` 吃掉。
- **埋点**：`session_interrupt` 每次 barge-in 由 2 条变 1 条。
- **回滚**：`git revert` 该提交即可（两条 arm 合回一条）。

### 已知残留：pump 的判定条件仍是一次相位读取

pump 判定用 `phaseBox.get() == .aiSpeaking`（`:470`），状态机原先判定用 `state.phase == .aiSpeaking`（`:103`）——**两处读的是同一个值，但在不同时刻**。中间隔着两次网络 `await`（interrupt 与 start 的发送）。

存在一个窄窗口：`.speechStarted` 时相位还是 `.processing`（AI 还没出声），而在这两次 await 期间 `ai.tts.start` + 首帧到达、相位翻成 `.aiSpeaking`，于是 `:482` 派发时状态机看到的是 `.aiSpeaking`。

- **改动前**：这个窗口里状态机会补发一次 interrupt——但按 §2 它**必定晚于 start**，所以同样达不到目的，只是多一个错记的帧。
- **改动后**：这个窗口不发 interrupt。

即：**两边都没能停掉那一轮回复，改动前后都不是「正确的行为」**，差别只是改动后少一个错记的帧。所以这不是本次引入的回归。

要真正关掉这个窗口，判定条件必须换成**跨 await 稳定**的信号：「当前是否有在飞的 TTS 轮次」。`TTSPlaybackCoordinator` 在 `ai.tts.start` 时就知道了（早于首帧音频，因此早于相位翻转），而**相位是滞后的那个**。这与 `07_` §2 的论证同轴（「归属必须由轮次本身承载」），也与 D2 / Stage 3 同轴。**本次不做**：它要动 `audioEventPump` 的签名并给协调器加读接口，属音频路径（High-Risk Path #1），值得单独立项。

## 6. 测试

### 6.1 先红：改动前的失败输出（原文）

```
✘ Test bargeInFromTheVADPathSendsExactlyOneInterrupt() recorded an issue at
    SpeakingRoomSessionWiringTests.swift:1041:5: Expectation failed: transcripts == ["__interrupt__"]
↳ 一次 barge-in 发了 2 次 interrupt：["__interrupt__", "__interrupt__"]
```

同一次运行的 tracker 输出把两次的来历摊开了——`timing_session_interrupt` 出现在 `vad_speech_start` 的相位翻转之后：

```
timing_phase_transition ["to": "recording", "stage": "vad_capture", "from": "aiSpeaking", "prev_event": "vad_speech_start"]
timing_playback_stop [...]
timing_session_interrupt ["prev_event": "playback_stop", ...]      ← 第 2 次，此时 start 早已发出
speech_session_transition ["to": "recording", "from": "aiSpeaking", ...]
tts_interrupt ["turn_id": "nil"]
```

### 6.2 新测试

| 测试 | 层 | 断言 |
|---|---|---|
| `bargeInFromTheVADPathSendsExactlyOneInterrupt` | 接线（真实 pump） | `emit(.speechStarted)` 后 `boundaries == [true]` 且 `transcripts == ["__interrupt__"]` |
| `holdDuringAISpeakingStillSendsTheInterrupt` | 状态机 | `(.aiSpeaking, .holdStart)` 仍产出 `.stopPlayback` + `.sendInterrupt` |

**为什么必须补一条接线级的**：既有那条 `speechSessionMiddlewareInterruptsPlaybackImmediately` 断言 `transcripts == ["__interrupt__"]`，但它**直接 `dispatch(.holdStart)`**，绕过了 pump——所以它钉住的是状态机那一次。**VAD 路径（唯一有生产者的那条）的 interrupt 计数一直是空白**，这正是 D3 能活到现在的原因。新测试走 `audioEngine.emit(.speechStarted)`，把缺口补上。

### 6.3 改写的既有测试：`vadDuringAISpeakingTriggersInterruptSideEffects`

原名与断言都把「VAD barge-in 会发 interrupt」当作契约。这条契约**本身就是缺陷**（§2 证明它必定晚于 start），所以：

- 改写为 `vadDuringAISpeakingStopsPlaybackWithoutASecondInterrupt`：`.stopPlayback` 仍在，`.sendInterrupt` 断言**取反**；
- 「一次 barge-in 只发一次、且在 start 之前」这个**要求没有被删掉**，而是挪到了更强的载体上——接线级的 `bargeInFromTheVADPathSendsExactlyOneInterrupt`，它跑的是真实 pump 路径，比手工 `reduce` 更接近生产。

按 `AGENTS.md` 的 Defect Fix Discipline，这里交代清楚：改的是**把缺陷当契约的那条断言**，不是把要求删掉。

## 7. 顺带记录：`.holdStart` 在生产代码里没有派发点

`Grep` 全仓：`.holdStart` 只出现在状态机的 case 臂、事件枚举声明（`SpeechSessionEvent.swift:30`）与测试里。**没有任何生产代码派发它。**

含义有两点，都不在本次范围：

1. `.holdStart` 相关的四条 arm 是**测试在养的死路径**（同 `07_` §2 的 `AudioPlaybackGate` 类：不是「没人调用」，而是「接不上」）。要不要删是独立决定。
2. 本次为它保留 `.sendInterrupt` 的理由是「那条路上没有 start，它是唯一的一次」——这在**今天**成立。若 hold-to-talk 将来真的接线，它必须自己解决「interrupt 早于 start」的顺序问题，不能照抄 VAD 路径。

## 8. 门禁

| 项 | 命令 | 结果 |
|---|---|---|
| `swift test` | `swift test --disable-sandbox` | **584 tests / 28 suites 全通过**（改动前 582；新增 2 条） |
| `FluentWorkHost` Debug build | `xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost -configuration Debug -destination 'generic/platform=iOS Simulator' build` | `** BUILD SUCCEEDED **` |
| 实现说明 | — | 本文，与代码和测试同一次提交 |

**未做真机验证，且这次的理由与 D1/`13_` 不同。** 前两次改的是埋点顺序与错误分类，失败模式在单测层完全可观测。**本次改的是 barge-in 的线上帧数**——而 `08_` §3 明确记载 barge-in 的端到端行为**从未在真机上验证过**（当时「没有在途帧可丢」，测不出东西）。

本次的可验证部分（「只发一次」）已被单测钉住，不依赖真机。但**「网关侧的顺序与记账是否正确」只有真机能回答**：需要网关**流式**发送 TTS + 一次人工打断，观察上一轮的 `delivered_chars` 是否为 0、新一轮是否被误打断。建议与 §5 的残留窗口一并进下一轮真机验证（`09_麦克风替身.md` 的 `FW_MOCK_MIC` 可去掉真麦克风依赖）。
