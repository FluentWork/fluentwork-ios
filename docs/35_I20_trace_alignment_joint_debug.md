# I20 Item 3 全链路 trace 联调

**票**：I20 Item 3 跨仓联调（iOS 收口）。  
**状态**：钉死与 backend `98dc63b` 相同的 `ai.turn.end` JSON；tracker 用同一组 `turn_id` + `log_id`。  
**关联**：不是 B15 70s 杀会话。backend 侧 `docs/37_I20_trace_alignment_实现说明.md`。

## 1. 要守住的原理

一轮说话在三层必须能对上。网关在用户 `user.speech.end` 之后发出：

```json
{"type":"ai.turn.end","turn_id":"turn-1","outcome":"ok","log_id":"volc-abc123"}
```

iOS 必须：

1. 解码出 `turn_id=turn-1`、`outcome=ok`、`log_id=volc-abc123`
2. 编出同一组字段（无 `session_id`）
3. `timing_ai_turn_end` 和 `timing_turn_duration` 都带这两个键
4. 空 `log_id` 不抢占后续真值；第二个非空 `log_id` 不覆盖第一个

backend 必须：不再发 `volc-turn-*` / `dev-echo-turn`。客户端 `turn-N` 就是权威 id。

## 2. 根因

B15-I3 已经把 `log_id` 写进 `ai.turn.end` 和解码器。联调时仍对不上：

1. `timing_turn_duration` 不走 `mark()`，漏了 `log_id`
2. `setLogID("")` 会占住 nil 槽，后面的真 id 进不去
3. 两端没有同一条 JSON fixture

## 3. 方案与文件

| 文件 | 职责 |
|---|---|
| `SpeechSessionTimingsRecorder.swift` | `markTurnEnded` 带 `log_id`；空串不写入 |
| `WSControlFrameDecodingTests.swift` | 钉死与 backend 相同的 map |
| `SpeechSessionMiddlewareTests.swift` | 入站帧 → tracker 双事件同键 |

## 4. 为何不折进已有路径

不把 trace 折进 B15 timeout 联调（`docs/32`）：那条测的是 `outcome=timeout` 杀会话。本票是 `outcome=ok` 时 id 能 join。

## 5. 影响面

- 状态：无相位变化
- 协议：入站/出站 `ai.turn.end` 字段与 backend `98dc63b` 一致
- 音频：无
- 发布：日志可用 `turn_id` + `log_id` 对齐 Volc `X-Tt-Logid`

## 6. 测试

```bash
# iOS
swift test --filter "aiTurnEndMatchesBackendTraceWireFixture|aiTurnEndTraceJoinsTurnIDAndLogIDOnTracker|speechSessionTimingsRecorderForwardsLogID"

# backend
cd fluentwork-backend
go test ./internal/voiceproto/ -run TestAITurnEndJSONMatchesIOSTraceWireFixture
go test ./internal/voicegateway/ -run 'CanonicalTurnID|TurnToOutboundFallback'
```
