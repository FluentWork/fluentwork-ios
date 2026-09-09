# 语音 Turn 超时兜底（B15 70s + I20 `client.turn.abort`）

**日期**：2026-09-09  
**状态**：iOS T-I20-1 已落地；backend `5c2e39f` 已接受 `client.turn.abort`。联调见 `docs/33_I20_client_turn_abort_joint_debug.md`。  
**读者**：后续改 SpeechSession / WSS / 音频循环的人  
**关联**：`docs/20_I20_voice_turn_boundary_pitfalls.md`（历史踩坑）· I20 T-I20-1 · B15 collectTurn

本文是 **turn 超时子系统的维护合同**，不是 PR 小结。改这条路径前先读完「不变量」和「不要做的事」。

---

## 1. 问题与拆分

实时语音有两个外形相似、语义完全不同的「等太久」：

1. **用户一直在说**（VAD 未判定结束）→ 客户端必须主动关掉这一轮 user speech，否则 PCM 会无限前向。
2. **用户已经说完**（已发 `user.speech.end`），gateway / 供应商迟迟不回 `ai.turn.end` → 客户端必须结束会话，否则 UI 钉在 processing。

历史文档（`docs/20`）把这两件事和「collectTurn 60s 误标 outcome=ok」写在一起。B15 只收口了第 2 条。I20 T-I20-1 收口第 1 条。

**禁止把两条路径收成一个 timer、一个 side effect、一个 `.failed`。**

| | I20 T-I20-1 录音 abort | B15 70s `turn_timeout` |
|---|---|---|
| 触发相位 | `.recording` | `.processingASR` 及之后的 processing |
| 前置 WSS | 已发 `user.speech.start`，**未**发 `user.speech.end` | 已发 `user.speech.end` |
| 时限 | 60s | 70s（供应商 collectTurn 60s + 10s buffer） |
| CancellationID | `speechSession.recordingAbortTimeout` | `speechSession.turnTimeout` |
| 事件 | `.recordingTimedOut` | `.failed("turn_timeout")` 或 `.turnTimeoutExpired` |
| 副作用 | `.sendTurnAbort` | `.endSession` |
| 会话 | **继续**，回到 `.waitingForAIAnswer` | **结束**，进入 `.failed` |
| 出站帧 | `client.turn.abort` | 最终 `session.end` |
| 是否启动 collectTurn | **禁止** | 已经在跑 |

`interrupt` 是第三条路：用户在 AI 说话时开口（barge-in）。不要用 `interrupt` 表达录音超时，也不要用 abort 表达 barge-in。

---

## 2. 范围 / 非目标

### 2.1 已落地（T-I20-1）

- 录音满 60s → 发 `client.turn.abort`，会话存活
- 纯状态机无 IO；timer 在 middleware
- abort 后不再发 `user.speech.end`、不再前向该轮 PCM
- `turn_id` 仍按 `turn-{N}` 消耗，避免下一轮复用

### 2.2 明确不做（留给后续票）

- **I21 T-I21-2** abort 后进入 `.waitingForAIAnswer`（已落地；下一轮 VAD 可开口）；B15 `outcome=timeout` 仍走 `.failed("turn_timeout")`
- Backend 接受 `client.turn.abort`（已落地，`fluentwork-backend` `5c2e39f`）

---

## 3. 协议

### 3.1 新帧（C→S）

```json
{"type":"client.turn.abort","turn_id":"turn-1","outcome":"timeout"}
```

| 字段 | 规则 |
|---|---|
| `type` | 恒为 `client.turn.abort` |
| `turn_id` | 可选；iOS 总会带。值为即将消耗的 `turn-{userTurnCount}` |
| `outcome` | `timeout` / `user_abandoned` / `error`（**不是** `ok`）。见 `docs/25_I20_turn_outcome.md` |
| `session_id` | **不发**。与 `user.speech.end` 一样，会话绑定在 WSS 连接上 |

Schema：`Shared/FluentWorkCore/Resources/Schemas/wss-control-frames-v2.json` → `$defs.clientTurnAbort`。  
编解码：`WSControlFrame.clientTurnAbort(turnID:outcome:)`。  
发送：`SpeechSessionClientProtocol.sendTurnAbort` → `DefaultSpeechSessionClient` → `transport.send(control:)`。

### 3.2 与已有帧的关系

```
user.speech.start     打开一轮 user speech（无 turn_id）
  ├─ binary PCM       仅在 SpeechCaptureGate 允许时前向
  ├─ user.speech.end  正常收口 → gateway collectTurn → ai.turn.end
  └─ client.turn.abort 超时收口 → 不得 collectTurn、不得关 WSS

interrupt             仅 barge-in（AI 正在说，用户开口）
session.end           整场会话结束（B15 失败路径会走到这里）
ai.turn.end           S→C；outcome=timeout 时 iOS 走 B15 失败，与 abort 无关
```

Gateway 当前 `default` 分支对未知 `type` 回 `error.code=unsupported_frame`。在 backend 落地前，真机录满 60s 会打到这条错误，会话可能被标失败。单测走 `InMemorySocketTransport`，不依赖 gateway。

### 3.3 Backend 应收的语义（尚未实现）

收到 `client.turn.abort` 时：

1. 视为当前未结束的 user speech 被取消
2. 丢掉该轮已缓冲 PCM
3. **不要**调用 `collectTurn` / `WaitTurnResult`
4. **不要**关 WSS，**不要**当 `session.end`
5. 等待下一帧 `user.speech.start`
6. 若该连接上没有打开的 user speech，当作 no-op（hold 路径可能尚未发 start）

---

## 4. 状态迁移

状态机仍是纯函数：`(inout SpeechSessionState, SpeechSessionEvent) -> [SpeechSessionSideEffect]`。  
Timer、WSS、AudioEngine **不得**进入 `SpeechSessionMachine.reduce`。

### 4.1 正常一轮（对照）

```
waitingUser / aiSpeaking
    │  vadSpeechStart / holdStart
    ▼
recording          ← 在这里启动 60s recordingAbortTimeout
    │  vadSpeechEnd / holdEnd     （取消 60s abort timer）
    ▼
processingASR      ← 在这里启动 B15 70s turnTimeout
    │  serverASRReceived
    ▼
processingLLM → processingReview 或 aiFirstAudioChunk
    │  ai.turn.end（outcome ≠ timeout）
    ▼
waitingForEvaluation
    │  evaluationReceived 或下一轮 VAD
    ▼
waitingUser / recording
```

`userTurnCount` 在 **离开 recording 进入 processingASR** 时 `+= 1`。  
出站 `user.speech.end.turn_id` 为 `"turn-\(count+1)"`（与 reduce 即将做的增量对齐）。

### 4.2 录音 abort（T-I20-1）

```
recording
    │  60s 到 → middleware 先 SpeechCaptureGate.abort()
    │           再 dispatch .recordingTimedOut
    ▼
waitingForAIAnswer userTurnCount += 1
                   effect: .sendTurnAbort(turnID: "turn-N", outcome: .timeout)
                   不进入 processingASR  →  因此 B15 70s 不会 armed
```

合法：仅 `(.recording, .recordingTimedOut)`。  
其它相位（含 `.processingASR`、`.waitingUser`）对该事件是 no-op。

系统中断期间（`suspendedPhase != nil`）仍接受 `.recordingTimedOut`，与 `.failed` / `.endTap` 同类，避免 60s timer 已关 PCM 但 reduce 被挂起过滤器丢掉。

### 4.3 B15 处理超时（对照，未改）

```
processingASR / LLM / Review
    │  70s 内未收到 ai.turn.end
    │  或收到 ai.turn.end outcome=timeout
    ▼
failed("turn_timeout") → .endSession → session.end
```

### 4.4 abort 之后用户再开口

```
waitingForAIAnswer
    │  下一轮 vadSpeechStart
    ▼
recording     ← 重新 beginSpeech()，60s abort timer 再 arm
```

abort **不是**终态。用户停顿后可以立刻开始下一轮。VAD 的 `discardActiveSpeech()` 清掉「仍在说话」标记，不必再等 1500ms silenceHold。

---

## 5. 数据流

### 5.1 组件与方向

```
LiveAudioEngine.events()
    │  speechStarted / pcmChunk / speechEnded
    ▼
SpeechSessionMiddleware  audioEngineEvents 循环
    │  SpeechCaptureGate 决定是否出站
    │  DefaultSpeechSessionClient
    ▼
WSS  (user.speech.start | PCM | user.speech.end | client.turn.abort)
    ▼
voice-gateway handler
    │  正常：HandleClientControl(user.speech.end) → collectTurn → ai.turn.end
    │  abort：待实现（§3.3）
    ▼
transportEvents 循环
    │  ai.turn.end / error / client.asr.transcription …
    ▼
dispatch SpeechSessionEvent → Machine.reduce → applySession + SideEffect
```

### 5.2 60s abort 时序（成功路径）

```
t=0     speechStarted
        gate.beginSpeech()
        出站 user.speech.start
        dispatch vadSpeechStart → recording
        middleware 启动 recordingAbortTimeout (60s)

t<60    pcmChunk 且 gate.shouldForwardPCM == true → 出站 binary

t=60    timer 到期且未被 cancel
        gate.abort()                    // 立刻停 PCM，关 isOpen
        dispatch recordingTimedOut
        reduce: recording → waitingForAIAnswer, sendTurnAbort(turn-N)
        取消 recordingAbortTimeout（离开 recording）
        interpret sendTurnAbort:
            gate.abort()                // 幂等
            audioEngine.discardActiveSpeech()
            send client.turn.abort

t>60    迟到的 VAD speechEnded
        gate.isOpen == false → 不发 user.speech.end，不 dispatch vadSpeechEnd

        迟到的 pcmChunk
        dropPCMUntilNextSpeech && !open → 丢弃，不发 binary
```

### 5.3 正常说完（abort 不得插队）

```
t<60    speechEnded
        gate 仍 open → endSpeech()
        出站 user.speech.end(turn-N)
        dispatch vadSpeechEnd → processingASR
        cancel recordingAbortTimeout     // 离开 recording
        arm B15 70s + ASR 15s 子计时
```

两条 timer 的 armed 窗口 **不相交**：abort 只在 recording；B15 只在 processing。

### 5.4 SpeechCaptureGate

存在原因：音频循环是独立 `.task`，abort 发生在另一条 task。不能靠读 `@MainActor` store 的 phase 来决定是否还发 PCM / `user.speech.end`。

| 方法 | open | dropPCMUntilNextSpeech | PCM | 迟到 speechEnded |
|---|---|---|---|---|
| `beginSpeech()` | true | false | 发 | 会发 `user.speech.end` |
| `endSpeech()`（正常 VAD 结束） | false | false | **仍发**（保持历史行为：非说话区间也前向） | 已处理过，不会再进 |
| `abort()` | false | true | **丢**直到下一次 `beginSpeech` | **忽略**，禁止 `user.speech.end` |

`endSpeech` 与 `abort` 对 PCM 的差异是有意的：正常结束后的尾包仍按旧契约前向；abort 必须切断，否则会重演 `docs/20` 里 80+ `provider audio forward failed`。

### 5.5 `turn_id`

- 分配点：离开 recording 时（VAD 结束 **或** abort），`userTurnCount += 1`，id = `"turn-\(userTurnCount)"`
- abort 也要消耗一个 id。否则下一轮 `user.speech.end` 会复用 `turn-1`，badge dedupe / 日志对不上
- `user.speech.start` 不带 `turn_id`（历史契约）

---

## 6. Timer 生命周期

全部用 TGReduxKit `.task(id:)`，**不要**在 Machine 里 `Task.sleep`。

| ID | 时限 | Arm | Cancel |
|---|---|---|---|
| `recordingAbortTimeout` | 60s | `previousPhase != .recording && newPhase == .recording` | 离开 `.recording`；`endSession` / `forceClose` |
| `turnTimeout` | 70s | recording → processingASR | 收到 `ai.turn.end`；进入 waitingUser / ended / failed |
| `processingASRTimeout` 等 | 15/45/30s | 进入对应 substage | 离开该 substage 或离开 processing |

Abort timer 到期时 **先** `captureGate.abort()` 再 dispatch 事件，避免 reduce 尚未跑完时音频循环又送出几帧 PCM。

B15 另有 `TurnTimeoutTracking.arm/disarm`，防止 70s timer 与 `ai.turn.end` 双发 `.failed`。录音 abort 不共用这个 tracking：离开 recording 就会 cancel 60s task，且 `.recordingTimedOut` 在非 recording 是 no-op。

---

## 7. 代码地图

| 文件 | 职责 |
|---|---|
| `SpeechSessionEvent.swift` | `.recordingTimedOut` |
| `SpeechSessionSideEffect.swift` | `.sendTurnAbort(turnID:outcome:)` |
| `SpeechSessionMachine.swift` | recording → waitingForAIAnswer；suspend 白名单 |
| `SpeechSessionMiddleware.swift` | 60s timer、`SpeechCaptureGate`、interpret abort、音频循环门闩 |
| `ProcessingTimeouts.swift` | **只有 B15** 的 15/45/30/70。录音 60s 是 middleware 的 `recordingAbortTimeout`，不要塞进这个 struct |
| `WSControlFrame.swift` | 编解码 `client.turn.abort` |
| `wss-control-frames-v2.json` | schema |
| `AppDependencies.swift` | `sendTurnAbort` / `discardActiveSpeech` 协议 |
| `DefaultSpeechSessionClient.swift` | 出站 abort 帧 |
| `LiveAudioEngine.swift` | `AudioSpeechActivityTracker.discard()`；`discardActiveSpeech()` 不 yield `.speechEnded` |

所有 `SpeechSessionClientProtocol` / `AudioEngineProtocol` 的 stub 必须实现新方法，否则编不过。

---

## 8. 不变量（改代码时当测试想）

1. Machine 零 IO。新增超时不要在 reduce 里起 Task。
2. Abort 不得进入 `.processingASR`（否则会误 arm B15）。
3. Abort 不得 dispatch `.failed` / `.endSession`。
4. Abort 不得发送 `user.speech.end`。
5. Abort 不得发送 `interrupt`。
6. Abort 必须消耗 `userTurnCount`。
7. 60s 与 70s 使用不同 CancellationID。
8. `client.turn.abort` 不带 `session_id`。
9. 迟到 `speechEnded` 在 gate 关闭后静默丢弃。
10. 现网 gateway 尚未识别该帧；联真机 60s 录音前先确认 backend。

---

## 9. 测试索引

| 测试 | 守住的不变量 |
|---|---|
| `recordingTimedOutAbortsTurnWithoutFailingSession` | waitingForAIAnswer + sendTurnAbort + 非 failed |
| `recordingTimedOutFromWaitingUserIsNoOp` | 非法相位 |
| `recordingTimedOutWhileSuspendedStillAbortsTurn` | 来电挂起仍能 abort |
| `vadSpeechEndAfterRecordingDoesNotSendTurnAbort` | 正常结束不走 abort |
| `illegalCombinations` 含 processingASR + recordingTimedOut | 处理中忽略 abort 事件 |
| `speechCaptureGateDropsPCMAfterAbortUntilNextSpeech` | abort 后门闩 |
| `speechCaptureGateEndSpeechStillForwardsPCM` | 正常结束 PCM 契约不变 |
| `audioSpeechActivityTrackerDiscardDoesNotEmitSpeechEnded` | discard ≠ reset |
| `recordingTimeoutSendsClientTurnAbortAndKeepsSessionAlive` | middleware：出 abort、不出 speech.end、会话不 end |
| `defaultSpeechSessionClientSendsTurnAbortWithoutSpeechEnd` | 线格式 |
| `clientTurnAbortEncodesTimeoutOutcome` / `DecodesWireFrame` | JSON |
| `wssControlFramesV2SchemaPinsTTSFramesAndKeepsAudioBinary` | schema 钉死 type/outcome、禁止 session_id |
| `controlFrameCodecRoundTripsKnownTypes` | 含 abort 帧 round-trip |

跑：

```bash
swift test --filter "recordingTimedOut|clientTurnAbort|TurnAbort|speechCaptureGate"
```

---

## 10. 后续维护入口

| 下一步 | 仓库 | 说明 |
|---|---|---|
| Gateway 接受 `client.turn.abort` | `fluentwork-backend` | 已落地 `5c2e39f`；联调 `docs/33` |
| Schema 真源同步 | `fluentwork-infra` `wss-control-frames-v2.json` | iOS 目前改的是镜像；`Scripts/sync-shared-schemas.sh` 会从 infra 覆盖 |
| T-I20-2 | iOS | 已落地：`docs/25_I20_turn_outcome.md` |
| T-I20-3 | iOS | 已落地：`docs/26_I20_system_prompt_builder.md` |
| T-I20-4 | iOS | 已落地：`docs/27_I20_turn_telemetry.md` |
| I21 | iOS | T-I21-2 已插入等待态（`docs/29`）；B15 `ai.turn.end outcome=timeout` 仍走 `.failed("turn_timeout")` |

改状态机时同步改：本文 §4、Machine 测试、`docs/20` 若涉及新的 turn 边界坑。
