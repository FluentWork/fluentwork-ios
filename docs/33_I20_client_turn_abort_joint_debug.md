# I20 `client.turn.abort` 联调

**票**：I20 录音 abort 跨仓联调（iOS 收口）。  
**状态**：iOS 出站帧已钉死与 backend `5c2e39f` 相同的 JSON。网关接受 abort、不杀会话。  
**关联**：不是 B15。松手之后的 `ai.turn.end outcome=timeout` 仍走 `.failed("turn_timeout")`。

## 1. 要守住的原理

用户还在开口（已发 `user.speech.start`，**未**发 `user.speech.end`）满 60s：

```json
{"type":"client.turn.abort","turn_id":"turn-1","outcome":"timeout"}
```

网关必须：

1. **不**回 `error.code=unsupported_frame`（iOS 会把它映射成 `.failed`，把还活着的会话打死）
2. **不** `collectTurn`，**不**发 `ai.turn.end`
3. **不**关 WSS
4. 下一轮 `user.speech.start` 仍可开口

iOS 必须：

1. 编出上面的 JSON（无 `session_id`，`outcome` 不得为 `ok`）
2. 相位 `.waitingForAIAnswer`，`failureReason == nil`，**不** `session.end`
3. abort 后再 VAD 能进 `.recording`

对照：说完松手才是 B15。abort 发生在还按着说话时。

## 2. 根因

iOS 先上了 abort。旧网关把未知 `type` 当成致命 `unsupported_frame`。backend `5c2e39f` 已接收该帧。本票只把出站 JSON、失败映射和「下一轮还能开口」钉进 iOS 测试，避免联调时两边各说各话。

## 3. 方案与文件

| 文件 | 职责 |
|---|---|
| `WSControlFrame.swift` | 已编解码 abort（未改） |
| `SpeechSessionMiddleware.swift` | 60s `.recordingTimedOut` → `sendTurnAbort`（未改） |
| `SocketTransportEventMapper.swift` | `unsupported_frame` 仍 → `.failed`（未改；联调若见到此码即网关回归） |
| `wss-control-frames-v2.json` | `$defs.clientTurnAbort` 与 backend v2 一致；v1 不加这帧 |

## 4. 为何不折进已有路径

- 不把 abort 折成 B15 `.failed("turn_timeout")`
- 不把 abort 折成 `interrupt`
- 不把 60s 录音超时改成 DEBUG 短窗口：联调测的就是这条合同

## 5. 影响面

- 状态：abort 后仍是 `.waitingForAIAnswer`；下一轮 VAD 进 `.recording`
- 协议：出站 JSON 与 backend wire 测试同一形状
- 音频：abort 停本轮 PCM；会话采集可继续
- 发布：录满 60s 不再因 `unsupported_frame` 掉线

## 6. 测试

```bash
# iOS
swift test --filter "clientTurnAbortMatchesBackendTimeoutWireFixture|recordingTimeoutSendsClientTurnAbortAndKeepsSessionAlive|mapperConvertsUnsupportedFrameToFailedAction"

# backend
cd fluentwork-backend
go test ./internal/voicegateway/ -run TestHandler_ClientTurnAbortKeepsSessionAlive
go test ./internal/voiceproto/ -run TestClientTurnAbortJSONRoundTrip
```

## 7. 真机步骤

1. 进说的房间，开口后 **按住不放 60 秒**（不要松手，否则会发 `user.speech.end`，变成 B15）
2. 期望：约 60s 后进入「本轮已超时」，WSS 还在，**没有**失败弹层 / `session.end`
3. 日志：出站 `client.turn.abort` `outcome=timeout`；**没有** `unsupported_frame`；**没有** `ai.turn.end(timeout)`；**没有** `turn_timeout_fired`
4. 再开口：能重新进录音

本地 DevEcho 可以测这条（abort 不依赖供应商卡住）。
