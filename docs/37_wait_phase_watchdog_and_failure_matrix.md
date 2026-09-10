# 等待相位 watchdog 与失败模式收口

**日期**：2026-09-10  
**状态**：代码与测试已齐。  
**对照**：`swift test` 403/403。FluentWorkHost Debug：iPhone 16 / OS 18.5 通过。  
**关联**：不是 B15 70s 杀会话；不是 I20 60s abort。本票收口「abort 落点在等谁」和「评价等待如何离开」。  
**问题分析与图例**：`docs/38_wait_phase_update_analysis.md`

## 1. 要守住的原理

两条等待相位 `isProcessing == false`，所以 **禁止** 误 arm B15 70s。这不表示它们可以无超时死等。

| 相位 | 实际在等什么 | 超时 | 超时后 |
|---|---|---|---|
| `waitingForAIAnswer` | 用户再开口（abort 已取消本轮 collectTurn） | 无。用户点「开始说话」或关会话 | — |
| `waitingForEvaluation` | 本轮 `feedback.badge` | 20s | `.waitingUser`，**不** `.failed` |
| `processingASR/LLM/Review` | `ai.turn.end` | B15 70s | `.failed("turn_timeout")` |

WSS **没有** eval.frame。会话级 review 走 REST（I16）。turn 级反馈只有 `feedback.badge`。

`log_id` 是 **per-session 首次非空**：`SpeechSessionTimingsRecorder.setLogID` 只写一次，后续 turn 的新 id 不覆盖。空串不占槽。

## 2. 根因

1. abort 落点叫 `waitingForAIAnswer`，UI 写「AI 思考中…（最长约 10s）」，但网关不会再答这一轮。10s 只是文案。
2. `.evaluationReceived` 只有状态机边，transport 不派发。多数 turn 没有 badge，评价等待只能靠用户再开口。
3. 生产重连走 `.socketReady` 而不是 `.reconnectSucceeded`。processing / `aiSpeaking` 上 socket 回来后相位不动，B15 仍可能在跑，当前 turn 已经没了。
4. `routeChanged` 只打点，采集 tap 不跟新设备格式。
5. `applySession(.connecting)` 每次都清 badge。连接中收到的 `feedback.badge` 会被紧随其后的 no-op session 事件抹掉。

## 3. 方案与文件

| 文件 | 职责 |
|---|---|
| `SpeechSessionMachine.swift` | `evaluationTimedOut` → waitingUser + stopPlayback；重连丢 in-flight turn；评价等待开口停播 |
| `SpeechSessionMiddleware.swift` | `feedback.badge` → badgeHit + evaluationReceived；20s evaluationTimeout；`routeChanged` → `reconfigureForRouteChange` |
| `SpeakingRoomFeature.swift` | 仅 **进入** connecting 时清 transcript/badge |
| `LiveAudioEngine.swift` | 路由切换重配 fullDuplex 并重装 tap，不重置 speech tracker |
| `SpeakingRoomView.swift` | abort 落点「本轮已超时」；评价等待写约 20s |

不把 abort 落点改成 `.waitingUser`：相位仍能把 abort 和正常等待分开打点。只改语义和文案。

不给两个等待相位共用 90s timer：abort 等的不是 AI；评价超时也不该杀会话。

## 4. 失败模式矩阵（当前行为）

| 场景 | 当前行为 | 测试 | 验证环境 |
|---|---|---|---|
| 录音满 60s | `client.turn.abort` → `waitingForAIAnswer`，会话继续 | `recordingTimedOutAbortsTurnWithoutFailingSession` / `recordingTimeoutSendsClientTurnAbortAndKeepsSessionAlive` | 模拟器 |
| 说完后 70s 无 `ai.turn.end` | `.failed("turn_timeout")` | `aiTurnEndOutcomeTimeoutFailsSessionWithTurnTimeout` | 模拟器 |
| 系统电话打断 | suspend，结束回 `waitingUser` | `audioEngineSystemInterruptSuspendsThenResumesToWaitingUser` | 模拟器；真机未验 |
| 进后台 | `scenePhase` → `forceClose` | ForceClose 单测 | 模拟器；真机未验 |
| processing 中 WSS 掉线 | 相位不动 + 3s 重连；回来则丢当前 turn → `waitingUser`；超时 → `degradedText` | `reconnectDuringProcessingDiscardsTurnWhenSocketReady` / `reconnectWindowTriggersAfterTimeout` | 模拟器 |
| `aiSpeaking` 中 TTS 无 `ai.tts.end` 且无 `ai.turn.end` | 剩余 B15 70s 杀会话 | 既有 B15 路径 | 模拟器 |
| `waitingForEvaluation` 中 TTS 停 | 评价 watchdog 照走；超时 `stopPlayback` | `evaluationTimedOutReturnsToWaitingUserWithoutEndingSession` | 模拟器 |
| 插拔耳机 / 蓝牙 | 重配 session + 重装 tap，相位不变 | `routeChangedReconfiguresCaptureWithoutChangingPhase` | 模拟器；真机未验 |
| 评价 / badge 不到 | 20s → `waitingUser` | `evaluationTimedOutReturnsToWaitingUserWithoutFailing` | 模拟器 |
| 60s abort 用户预警 | **无** 50s UI。Known issue | — | — |

默认手动模式下 barge-in：AI 说话时点「开始说话」→ `beginManualSpeech` → `.vadSpeechStart` → `.stopPlayback` + WSS `interrupt`。能量 VAD 默认关。会话 category 是 `.playAndRecord` + `.voiceChat`（系统 AEC）。真机 AEC 未验。

`degradedText`：弱网 / 3s 重连失败进入。UI「网络不稳定」，无输入框。`reconnectSucceeded` 不会把降级拉回语音。Known issue。

## 5. 为何不折进已有路径

- 不把评价 20s 折进 B15：B15 杀会话，评价超时只跳过 badge。
- 不把 abort 落点改回 `waitingUser`：tracker `from/to` 还要能看见 abort。
- 不把 `feedback.badge` 当成会话 review：那是 I16 REST。
- 不在 `swift test` 里等 20s：中间件测派发 `.evaluationTimedOut`，时长是 `ProcessingTimeouts.evaluationWait`。

## 6. 影响面

- **状态**：abort UI 不再假装等 AI；评价等待有离开合同；processing 重连丢 turn。
- **协议**：多消费已有 `feedback.badge`，不新增 WSS 帧。
- **音频**：路由切换重装 tap；评价超时 / 评价等待开口 / 重连丢 turn 会停播。
- **发布**：模拟器主路径更不容易死等。真机 Opus（I15）、电话打断、蓝牙仍未验。

## 7. 测试

```bash
swift test --filter "evaluationTimedOut|evaluationArrival|feedbackBadgeLeaves|feedbackBadgeBeforeTurnEnd|reconnectDuringProcessing|socketReadyWhileReconnecting|routeChangedReconfigures|speakingRoomWaitingForAIAnswer|applySessionConnectingAgain"
```

## 8. 本票明确不做

- I15 真机 Opus / 火山 SDK（仍 blocked）
- I14 / I16–I19 UI（I15 卡住时下一手是 I14）
- ISSUE-08 Instruments 实测数字
- 60s abort 的 50s 预警 UI
- `degradedText` 文本输入与回语音
