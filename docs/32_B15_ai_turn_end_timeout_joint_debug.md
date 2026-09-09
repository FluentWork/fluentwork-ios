# B15 `ai.turn.end outcome=timeout` 联调清单

**状态**：iOS 侧已具备；待 gateway 真发 `outcome=timeout`。
**关联**：I21 已收口。本路径 **不是** I20 录音 abort，也 **不是** `waitingForAIAnswer`。

## 1. 要核对的合同

用户已经 `user.speech.end`，gateway collectTurn 窗口耗尽后下发：

```json
{"type":"ai.turn.end","turn_id":"turn-1","outcome":"timeout","log_id":"…"}
```

iOS 必须：

1. 解码 `WSControlFrame.TurnOutcome.timeout`（已有 `aiTurnEndWithOutcomeTimeout`）
2. middleware **不要** 派发 `.aiTurnEnd`（否则会进 `.waitingForEvaluation`）
3. 派发 `.failed("turn_timeout")` → 相位 `.failed`，`failureReason == "turn_timeout"`，`.endSession`
4. 与客户端 70s `turn_timeout_fired` 同一条失败 UX

对照：I20 录音 60s 发 `client.turn.abort` outcome=timeout，会话进 `.waitingForAIAnswer`，**禁止** `.failed("turn_timeout")`。

## 2. iOS 已覆盖

- 解码：`Tests/FluentWorkCoreTests/Networking/WSControlFrameDecodingTests.swift`
- middleware：`aiTurnEndOutcomeTimeoutFailsSessionWithTurnTimeout`

```bash
swift test --filter "aiTurnEndWithOutcomeTimeout|aiTurnEndOutcomeTimeoutFailsSessionWithTurnTimeout"
```

## 3. 和 backend 联调步骤

1. 确认 voice-gateway 在 collectTurn 超时后发带 `outcome` 的 `ai.turn.end`，值为 `"timeout"`（不是省略字段、不是 `"ok"`）
2. 真机 / 模拟器走完一轮：开口 → 松手 → **不要** 让供应商在 70s 内回 TTS
3. 期望 UI：录音失败 / `turn_timeout`，WSS `session.end`，**不是**「正在评价」或「AI 思考中」
4. 对照日志：`transport_rx` `ai.turn.end(timeout)`，随后 `speech_session_transition` 进入 `failed`；不应出现 `client.turn.abort`

## 4. 不要做的事

- 不要把这条失败折进 I21 `waitingForAIAnswer`
- 不要让 `outcome=timeout` 走普通 `.aiTurnEnd` → `waitingForEvaluation`
- backend 未发 `outcome` 时，iOS 仍当普通 turn end（进评价等待），70s 客户端兜底才会 `turn_timeout_fired`
