# B15 `ai.turn.end outcome=timeout` 联调

**票**：B15 跨仓联调（iOS 收口）。  
**状态**：iOS 已落地。v2 schema、未知 `outcome`、开场 greeting 与 timeout 失败路径单测通过。  
**关联**：I21 已收口。本路径 **不是** I20 录音 abort，也 **不是** `waitingForAIAnswer`。

## 1. 要守住的原理

用户已经 `user.speech.end`，gateway `collectTurn` 窗口耗尽后下发：

```json
{"type":"ai.turn.end","turn_id":"turn-timeout-1","outcome":"timeout","log_id":"volc-log-timeout"}
```

iOS 必须：

1. 解码 `WSControlFrame.TurnOutcome.timeout`
2. middleware **不要** 派发 `.aiTurnEnd`（否则会进 `.waitingForEvaluation`）
3. 派发 `.failed("turn_timeout")` → 相位 `.failed`，`failureReason == "turn_timeout"`，`.endSession`
4. 与客户端 70s `turn_timeout_fired` 同一条失败 UX

对照：I20 录音 60s 发 `client.turn.abort` outcome=timeout，会话进 `.waitingForAIAnswer`，**禁止** `.failed("turn_timeout")`。

WSS 合同只扩 **v2**。v1 是冻结的 V1.0 快照（`type` + `turn_id`）。线上 speaking room 走 V2；Codable 不按 JSON Schema 校验入站帧。

## 2. 根因

backend `834729d` 已把 `outcome` / `log_id` 写到线上 `ai.turn.end`。iOS 原先有三处接不住：

1. **v2 镜像落后**：`$defs.aiTurnEnd` 只有 `type`+`turn_id`。契约测试无法钉死 B15 字段。
2. **开场 greeting**：DevEcho / Volc `Start()` 在用户开口前发 `outcome=ok` 的 bootstrap `ai.turn.end`。I21 把 `.aiSpeaking` + `.aiTurnEnd` 一律送进 `.waitingForEvaluation`，首屏卡在「正在评价」。
3. **未知 `outcome` 字符串**：`decodeIfPresent(TurnOutcome.self)` 会让整帧失败。iOS 看不到 timeout，只能等 70s 客户端兜底。

## 3. 方案与文件

| 文件 | 职责 |
|---|---|
| `WSControlFrame.swift` | `outcome` 先解成 `String`，再用 `TurnOutcome(rawValue:)`；未知值 → `nil` |
| `SpeechSessionMachine.swift` | processing\* + `.aiTurnEnd` → `.waitingForEvaluation`；`.aiSpeaking` 且 `userTurnCount > 0` → 评价等待；尚未开口 → `.waitingUser` |
| `SpeechSessionMiddleware.swift` | `outcome == .timeout` → `.failed("turn_timeout")`（已有，未改） |
| `wss-control-frames-v2.json` | `$defs.aiTurnEnd` 增加可选 `outcome` / `log_id` |
| `wss-control-frames-v1.json` | **不改** |

## 4. 为何不折进已有路径

- 不把 timeout 折进 I21 等待态：那是会话继续；B15 要杀会话。
- 不把 greeting 折成「所有 `ai.turn.end` 都回 `waitingUser`」：用户说过话之后仍要进评价等待。
- 不改 v1：V1.0 已冻结。backend 把 v1 和 v2 绑在一起改是冻结违规；iOS 只对齐现行 V2。

## 5. 影响面

- 状态：开场 `ai.turn.end` 回 `.waitingUser`；用户轮次仍进 `.waitingForEvaluation`；`outcome=timeout` 仍 `.failed`
- 协议：v2 `aiTurnEnd` 声明 `outcome` / `log_id`；v1 不变；运行时解码对未知 outcome 更宽容
- 音频：不改采集 / TTS
- 发布：speaking room 现网帧带 `outcome` 时，timeout 不再误进评价等待或卡住 70s

## 6. 测试

- 解码：`aiTurnEndWithOutcomeTimeout`、`aiTurnEndMatchesBackendTimeoutWireFixture`、`aiTurnEndWithUnknownOutcomeDecodesAsNilOutcome`
- middleware：`aiTurnEndOutcomeTimeoutFailsSessionWithTurnTimeout`、`bootstrapAITurnEndOutcomeOkReturnsToWaitingUser`
- 状态机：`aiTurnEndHappyPathGreetingReturnsToWaitingUser`、`aiTurnEndAfterUserTurnReturnsToWaitingForEvaluation`
- schema：`wssControlFramesV2SchemaPinsTTSFramesAndKeepsAudioBinary` 钉死 v2 `outcome` / `log_id`

```bash
# iOS
swift test --filter "aiTurnEndWithOutcomeTimeout|aiTurnEndMatchesBackendTimeoutWireFixture|aiTurnEndOutcomeTimeoutFailsSessionWithTurnTimeout|aiTurnEndHappyPathGreeting|bootstrapAITurnEnd|wssControlFramesV2SchemaPinsTTSFrames"

# backend wire
cd fluentwork-backend
go test ./internal/voicegateway/ -run TestHandler_AITurnEndCarriesTimeoutOutcomeOnWire
go test ./internal/voiceproto/ -run "TestSchemaAITurnEndIncludesOutcomeAndLogID|TestSchemaV1AITurnEndStaysFrozenWithoutOutcome"
```

## 7. 和 backend 联调步骤

1. 确认 voice-gateway 在 collectTurn 超时后发带 `outcome` 的 `ai.turn.end`，值为 `"timeout"`（不是省略字段、不是 `"ok"`）
2. 真机 / 模拟器走完一轮：开口 → 松手 → **不要** 让供应商在 70s 内回 TTS
3. 期望 UI：录音失败 / `turn_timeout`，WSS `session.end`，**不是**「正在评价」或「AI 思考中」
4. 对照日志：`transport_rx` `ai.turn.end(timeout)`，随后 `speech_session_transition` 进入 `failed`；不应出现 `client.turn.abort`

## 8. 不要做的事

- 不要把这条失败折进 I21 `waitingForAIAnswer`
- 不要让 `outcome=timeout` 走普通 `.aiTurnEnd` → `waitingForEvaluation`
- backend 未发 `outcome` 时，iOS 仍当普通 turn end（开场回 waitingUser，用户说过话则进评价等待），70s 客户端兜底才会 `turn_timeout_fired`
- 不要把 v1 schema 改成和 v2 一样

`outcome=timeout` → `.failed("turn_timeout")` 未改。I20 abort → `.waitingForAIAnswer` 未改。
