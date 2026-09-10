# 评估超时把话尾剪掉了

**日期**：2026-09-11
**状态**：代码与测试已齐。门禁见 §5。
**触发**：真机 —— 「返回的语音播放不全，有时候是前半段，有时候是后半段」+ 日志 `total_ms 36607` 的 `playback_stop`
**关联**：`docs/46`（传输层丢弃可观测）· `docs/43`（助手音频）· meta `77_` F19

## 1. 守住的不变量

**停播的时机属于音频，不属于任何别的定时器。** 一个和音频无关的超时，不该决定话说完了没有。

## 2. 根因：两个时钟互相不知道对方

```swift
case (.waitingForEvaluation, .evaluationTimedOut):
    // Badge never arrived. Keep the session; leftover TTS is dropped.
    state.phase = .waitingUser
    state.processingSubStage = nil
    effects.append(.stopPlayback)          // ← 剪在这里
```

「leftover TTS is dropped」这个推理**假设音频已经播完**。但两个时钟毫无关系：

| | 由什么决定 |
|---|---|
| **评估超时** | 固定预算 `evaluationWait = .seconds(20)` |
| **播放** | AI 说了多长 —— 网关在轮末一次性推整轮音频 |

真机日志把两者并排放在了一起：

```
timing_ai_first_chunk  sequence 138 → 413   payload 3200
                       276 帧在 88 毫秒内推完(15901.971 → 15989.856)
                       276 帧 × 100ms = 27.6 秒的音频
phase_transition       waitingForEvaluation → waitingUser   total_ms 36607  delta_ms 20617
timing_playback_stop                                        total_ms 36607
tts_interrupt          turn_id "nil"
```

`20617ms` 对 `20s` —— 精确吻合。**27.6 秒的音频,放到 20.6 秒被 `playerNode.stop()` 掐掉**,而 `stop()` 会清空整个已排队列。

**两个自证的旁证：**

1. **兄弟分支相反**。徽章按时到达的 `evaluationReceived` 落到**同一个相位**、**不停播**。同一时刻同一相位,处理却相反 —— 超时分支是异类。
2. **`docs/46` 的埋点先排除了门禁**。用户搜遍日志没有 `transport_audio_dropped`,276 帧全部投递。上一轮的"水位线丢弃"假设**被自己的埋点否掉了** —— 这正是它该干的事。

## 3. 方案

从 `evaluationTimedOut` 分支移除 `.stopPlayback`。

**为什么不需要它**：停播的每一条**真实**理由都已经有自己的出口 ——

| 场景 | 谁停的 |
|---|---|
| 用户打断 | `(.waitingForEvaluation, .vadSpeechStart)` / `(.aiSpeaking, .vadSpeechStart)` → `.stopPlayback` |
| 会话结束 | `.endSession` / `.forceClose` |
| 系统中断 | `.interruptedBySystem` → `.stopPlayback` |

超时是**唯一**一个和音频无关却停播的路径。

**行为变化**：评估超时后,话会继续说完,用户可以随时开口（开口即 barge-in 停播）。这正是全双工该有的样子。

## 4. 影响面

- **播放**：长于 20 秒的回复不再被剪尾。这是本产品第一次能完整听完一段长回复。
- **相位**：`waitingForEvaluation → waitingUser` 不变,只是不再附带停播。
- **协议 / 状态机其余部分**：零改动。

## 5. 门禁

```bash
swift test                      # 426/426
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试（先红后绿）：

| 测试 | 守住的不变量 | 修复前 |
|---|---|---|
| `evaluationTimeoutEndsTheTurnWithoutCuttingPlayback` | 评估超时结束回合,但不剪音频 | `Expectation failed: (effects.contains(.stopPlayback) → true) == false` |

既有测试 `evaluationTimedOutReturnsToWaitingUserWithoutFailing` **连同更新** —— 它把旧契约（超时必须停播）钉住了。按 `agents/shared/defect-fix-discipline.md`：旧契约不成立时改测试,并在测试里写明为什么。该断言已改为 `== false` 并附上原因。

## 6. 与 badge 的关系（F19 之后的核查）

本票**只动了一个转移的副作用列表**，以下全部未动：`feedback.badge` 帧的处理（`badgeHit` 与 `evaluationReceived` 无条件派发）、徽章渲染（按时间过滤，不看相位）、状态机的 `evaluationReceived` 分支、`EvaluationArrivalBox`。

**但两个时钟确实又碰上了：**

```
评估窗口  evaluationWait       = 20s   固定
徽章可见  visibleWindowSeconds = 4s    固定
播放      ── 由 AI 说了多长决定 ── 无上界
```

本票之前，20s 超时会把音频剪断，所以"徽章出现时房间是安静的"。现在音频继续，**长回复会盖过徽章 4 秒的整个显示窗口** —— 用户注意力在听，可能根本看不到徽章。这与本票是**同一类错误**：用一个固定时钟去管一件长度由内容决定的事，只是方向相反。

三条待验已记录在 meta `77_` **P1-8**（含验法）。

## 7. 本票不做

- **不改 `evaluationWait` 的 20 秒**：它管的是"徽章来得太晚",与音频无关。改它只是把问题推远。
- **不做"按音频时长排程停播"**：客户端不知道音频还剩多少。真要感知播放完毕,应该由播放节点回调驱动,那是另一票。
- **不动水位线生命周期**：见 meta `77_` P1-7。
