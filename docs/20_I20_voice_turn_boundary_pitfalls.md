# I20 语音 Turn 边界踩坑全表（B13 → B14 → B15 实战）

**作者**：iOS + Backend，2026-09-02
**状态**：当前生产路径已经修复；本文档为接力下个 / 复盘用

---

## TL;DR

我们这一周撞了 **4 个独立但外形相似的 turn 边界 / 终结点问题**，每个单独修都不复杂，但合在一起说明 **实时语音 turn 流的脆弱性来自三个交汇点：VAD、ASR、网络后半段**。本文档按时间倒序记录症状 → 根因 → 修复 → 后续检查清单。

---

## 1. Provider audio forward failed ×80（2026-09-02 20:46~20:47，**未修复，仅记录**）

### 1.1 现象

iOS ↔ Backend 端到端日志中：

```json
{"time":"2026-09-02T20:46:29.673","msg":"voice user speech frame","type":"user.speech.start"}
{"time":"2026-09-02T20:46:31.244","msg":"voice user speech frame","type":"user.speech.end"}
{"time":"2026-09-02T20:46:31.244","msg":"voice.duplex.collect_turn.start"}
{"time":"2026-09-02T20:47:31.244","msg":"voice.duplex.collect_turn.done","event_count":2,"transcript_len":0,"assistant_text_len":0,"asr_started_ms":0,"asr_done_ms":0,"duration_ms":60000,"outcome":"ok"}
{"time":"2026-09-02T20:47:31.244","msg":"turn result captured","transcript":"","assistant_text":"","active_turn_id":"volc-turn-42"}
{"time":"2026-09-02T20:47:31.244","level":"WARN","msg":"provider audio forward failed","err":"failed to write msg: use of closed network connection"}
... // 同一条 warn 重复 80+ 次，时间戳全部在 20:47:31.244 ~ 20:47:31.367
{"time":"2026-09-02T20:47:31.374","msg":"voice session ended","err":"failed to read: ... connection reset by peer"}
```

### 1.2 三个独立缺陷叠加

#### a. `collectTurn.done` 在 60s 超时后报 `outcome:"ok"`

```go
// voicepoc/volc_duplex.go
func (s *DuplexSession) collectTurn(...) (TurnResult, error) {
    // ...
    if !seenUserProgress || !seenResponse {
        return false  // 这里让 collectTurn 退出循环
    }
    out.AssistantText = strings.TrimSpace(text.String())
    return true
}
```

`collectTurn` 用 `response.output_audio.done` 或 `response.done` 当 turns 终止信号。60s 内如果 Volcengine 没有推进 user progress 或 response，**没人显式标记 collectTurn 为失败**，它以 `outcome=ok` 返回。

**真实状况**：transcript=0、assistant_text=0、duration_ms=60000 —— 一点都不是"ok"。

#### b. iOS 的 WS 端后续还在发送 binary 音频帧

60s 超时触发后，iOS 没有"用户对话框超时"的兜底重连逻辑。如果用户继续说话、或 LiveAudioEngine 还在 tap、`pcmBuffer` 还有未提交数据，binary chunks 会持续倒进 backend 的 `handleAudio`：

```go
outbound, err := rt.provider.HandleClientAudio(ctx, data)
if err != nil {
    h.logger.Warn("provider audio forward failed", "err", err)
    // ...
}
```

#### c. `HandleClientAudio` 失败时**继续尝试写 iOS WS**

```go
if err != nil {
    h.logger.Warn(...)
    return writeJSON(ctx, conn, voiceproto.ErrorFrame{...})  // 写已经死的 iOS WS
}
return writeProviderOutbound(ctx, conn, outbound)           // 写已经死的 iOS WS
```

每次写都会立即报 `use of closed network connection`，并在循环里**全部打 WARN 而不退避、不聚合、不停止**。

### 1.3 修复方向（**未做，留给 B15**）

| 待做 | 优先级 | 位置 |
|------|--------|------|
| `collectTurn` 显式返回 `outcome=timeout` 并把这个状态透出 | **P0** | `voicepoc/volc_duplex.go` |
| iOS 在收到 `ai.turn.end` 后如果在 Xs 内没收到，进入 `processing → waitingUser` 兜底，**不**再发送 binary audio | **P0** | iOS `SpeechSessionMiddleware` |
| 后端 `handleAudio` 在 `conn.Write` 失败时**立刻退出 session** 而不是继续 try | **P1** | `voicegateway/handler.go` |
| warn 日志加 **去重 / 采样** —— 60s 80 条一样的 warn 是噪声 | **P1** | `voicegateway/handler.go` |
| iOS `speechEngine.events()` 把 turn_timeout 当成 terminal 事件上报到 reducer | **P2** | iOS reducer |

---

## 2. iOS 上 Ghost `sendSpeechBoundary`（2026-09-02 修复 ✅）

### 2.1 现象

```text
[Tracker] timing_vad_speech_start (用户真开始说话)
[Tracker] timing_phase_transition → recording
[Tracker] speech_turn_ended turn-1 (用户结束说话)
[Tracker] timing_phase_transition → processing
[Tracker] server_asr_received_full text:"Relax."
[Tracker] timing_phase_transition → waitingUser
... 
iOS error: sockettransporterror error 3
```

iOS phase 被钉死在 "处理中"。没有超时 error 之前，看起来像是 LLM 慢。

### 2.2 根因

iOS middleware 在收到 `client.asr.transcription`（服务端 ASR 转写）时，又调用了一次 `sendSpeechBoundary(false, turnID:nil)`——这是**第二个**`user.speech.end`：

```swift
// 错误的代码（已删除）
case let .control(.clientASRTranscription(text, turnID)):
    tracker.track("server_asr_received_full", ...)
    // BUG: 在这里又发了一次 user.speech.end，导致 backend 收到两次终结
    try await speechClient.sendSpeechBoundary(started: false, turnID: nil, text: nil)
```

时间链条：
1. VAD 触发 `user.speech.end`（带真实音频）→ backend 收集 → Volcengine commit → 出 ASR text
2. iOS 收到 ASR text 后**又**发了 `user.speech.end`（这次 audio 队列已空）→ backend 把它当新一轮 → 等 60s → 等不到 → 60s timeout

第二个 `user.speech.end` 的"音频"是 0 字节，Volcengine 也不会触发 ASR（`input_audio_buffer.commit` 在 16ms 后收到一个空 buffer），backend 那边的 `collectTurn` 等了 60s 收不到 `response.output_audio.done` ... 最终表现就是"WSS 不动，等 60s"。

### 2.3 修复

```swift
case let .control(.clientASRTranscription(text, turnID)):
    tracker.track("server_asr_received_full", "text_bytes": ..., "text": text)
    timings.mark("server_asr_received", ...)
    // NOTE: We intentionally do NOT call `sendSpeechBoundary` here.
    // The original iOS VAD already fired `user.speech.end` when the user
    // actually stopped speaking, which is what triggered the Volc commit
    // that produced this transcript. Re-emitting `user.speech.end` on
    // receipt of the relay frame would start a phantom second turn with
    // no audio, causing the gateway to wait 60s for nothing.
```

测试用 `serverASRFromTransportDoesNotResendSpeechBoundary` 守住这条不变量。

### 2.4 教训

> **不要在收到下游事件时再触发上游终结点**。turn 边界（`user.speech.start`/`user.speech.end`）是**single-source-of-truth**：只从 iOS VAD 来，不要从 ASR 回灌。

---

## 3. VAD `silenceHold` 太短导致 half-spoken capture（2026-09-02 修复 ✅）

### 3.1 现象

```json
{"msg":"turn result captured","transcript":"今天学习。"}   // 应该是"今天学习 Linux。"
{"transcript":"Relax."}                                // 应该是完整的句子
```

后端拿到的 transcript 总是句子不完整。

### 3.2 根因

iOS `LiveAudioEngine.AudioSpeechActivityTracker` 默认 `silenceHold = .milliseconds(350)`：

```swift
init(
    speechThreshold: Float = 0.015,
    silenceHold: Duration = .milliseconds(350)  // 太短
)
```

**350ms 触发条件**：用户在两个词之间稍长停顿（中文里"今天学习……Linux"中间会有几百 ms 自然停顿），VAD 直接判定用户说完了，把 PCM feed 截止，丢字。

### 3.3 修复

```swift
silenceHold: Duration = .milliseconds(1500)
```

中文自然语速下两个词之间的停顿很少超过 1.2s；设到 1500 留有余量也不会让用户等太久。

### 3.4 配套的潜在问题（待观察）

- **中文超出 1500ms**：用户思考时停顿超 1.5s，会被截成两段。可以在 prod 跑一周看分布，如果很多用户投诉，再调到 1800ms；
- **英文长复合句**：Clauses 之间停顿超过 1.5s 也可能被截。data-driven 后再调。

### 3.5 教训

> **VAD silenceHold 不是 universal constant**。中文 1500ms 是一个经验起点；不同语言、母语者 vs 非母语者都该有自己的 budget。

---

## 4. B13 Client ASR（端侧 Apple Speech）失败以及为什么弃用（2026-08 → 2026-09-01）

### 4.1 B13 原本设想

backend 提供 `VOICE_CLIENT_ASR_REQUIRED` gate；iOS 发送 `user.speech.end` 时携带本地 Apple Speech 转写结果（`text`）。Apple Speech 走端侧，不依赖网络。

backend 端实现见 `internal/voicegateway/handler.go`：

```go
if frameType == voiceproto.TypeUserSpeechEnd && h.clientASRRequired {
    var end voiceproto.UserSpeechEnd
    if strings.TrimSpace(end.Text) == "" {
        return writeJSON(ctx, conn, voiceproto.ErrorFrame{
            Type: voiceproto.TypeError,
            Code: "client_asr_required",
            Message: "user.speech.end.text is required when VOICE_CLIENT_ASR_REQUIRED is enabled",
        })
    }
}
```

backend 这一侧实现 + 4 个测试都到位了。但 iOS 那一侧几次想接都失败了：

### 4.2 B13 Phase 2 联调**七次失败**，每次症状不同

| 失败轮次 | 现象 | 根因 | 修复 commit |
|---------|------|------|-----------|
| **F1** | 真机 simctl 报 `Speech.AppleSpeech.requiresOnDeviceRecognition` not_available | `requiresOnDeviceRecognition=true` + 中文 Siri 不在端侧可用 | `205c83f fix(asr): remove requiresOnDeviceRecognition to fix not_available on real devices` |
| **F2** | 即便调通 sim 仍 "authorization" 报 denied | 没先调 `requestAuthorization()` 就检查 status | `f11df7d fix(asr): call requestAuthorization before checking speech recognition permission` |
| **F3** | B13 错误码与 backend 默认错误码格式不一致 | iOS 期望 `UNAUTHENTICATED`，backend 给的是 `INTERNAL` | `2d939b9 fix(speech): match backend's UNAUTHENTICATED error code` |
| **F4** | Cached token 401 后没有 auto-recover | 401 后没有 invalidate stale token | `ddc9018 fix(speech): auto-recover from stale cached token on 401` |
| **F5** | 录音结束后把 `AVAudioSession` deactivation，导致下次录音无输入 | 之前的 PR 写了 `stopCapture` 里 deactivation 一刀切 | `75e71bc fix(audio): remove audio session deactivation in stopCapture` |
| **F6** | Apple Speech 在端侧跑得慢，平均 800ms / 句 | 端侧 STT 在 background queue + 长 audio buffer | 卡在这一步，**决定改方案** |
| **F7** | 即使 Apple Speech 出来，iOS 还要再做 ASR → text 字段回灌 | 引入双 ASR 路径（端侧 + 服务端），架构复杂度翻倍 | **结论：弃用端侧，改 server-side ASR** |

### 4.3 决策：B14 改 server-side ASR

7 次失败后，**改方案**：
- iOS 不再做 ASR，PCM 直发 backend
- backend 转发给 Volcengine Duplex，**Volcengine 自己 ASR + TTS**
- backend 把 Volcengine 的 `conversation.item.input_audio_transcription.*` 事件转成 `client.asr.transcription` 帧回灌给 iOS
- 删 iOS 上所有 client-side ASR 代码（`RawClientASRTranscriber`、`ClientASRTranscriber.swift` 等）

### 4.4 经验：客户端 ASR 不该是默认值

> **端侧 ASR 是 fallback，不该是 day-one 路径**。失败的根因是：iOS 上 Apple Speech 的可用性、和 STT 准确度、和延迟、错误码不一致 —— 都是平台信号的不确定性。把不确定性放在 hot path 上 → 项目就被不确定性拖。

回头看，B13 客户端 ASR 在 prod 环境**永远会失败**于至少一个 platform/version 组合。最后改的 server-side ASR 反而一次通过，让我们在当天能联调出三轮对话的数据流。

### 4.5 还留着哪些 B13 部件

- backend `Handler.clientASRRequired` 字段 + gate 逻辑（标记为 B13 历史，不删除）—— 它**目前不启用**，但代码很干净，留着给以后真要切回端侧 ASR 时
- `WSAudioFrameDecoder` + `VolcengineOpusFrameDecoder` stub —— 当前 backend 还没 relay AI 音频给 iOS，等 Opu 真正出现时再实装
- 测试覆盖：`TestHandler_RejectsEmptyTextWhenClientASRRequired` 等 4 个 case —— 全部仍然 PASS

---

## 5. 综合教训 / 给下一个写实时语音的人

| 教训 | 误以为 | 实际 |
|------|--------|------|
| Turn 边界是 single-source-of-truth | backend 收 ASR 就停 | backend 永远不要因为**回灌**事件自己再加 `user.speech.end` |
| VAD silenceHold 设静态值就够了 | 语言无影响 | 必须按语料调；中文 1500ms 是起点，要数据验证 |
| Client ASR = 更可靠 | 离线下也能用 | 不确定性高；用作 fallback，不要作主路径 |
| Provider 超时 = error | 60s 是 OK 区间 | 60s 超时必须**显式**标记 `outcome=timeout`，不能忍 |
| 失败后的 warn 越多越好 | 方便 debug | 失败级联场景下，warn 是噪声，要去重 / 采样 |
| iOS phase 卡住 = 网络断 | "正在处理" 是普通现象 | 必须能用错误码区分 "等待中" 和 "卡死了等不到东西" |

---

## 6. 配套清单（防再犯）

### iOS

- [x] `LiveAudioEngine.AudioSpeechActivityTracker.silenceHold = 1500ms`
- [x] `SpeechSessionMiddleware` 不再为 `client.asr.transcription` 触发 `sendSpeechBoundary`
- [x] 回归测试 `serverASRFromTransportDoesNotResendSpeechBoundary`
- [x] 文档 `docs/13_ClientASR集成与使用指南.md` 更新为 "B14 后此协议已废弃"
- [ ] 加 turn_timeout 兜底（provider 60s 响应窗口）
- [ ] 增加音频 decoder 延时指标的 unit test

### Backend

- [ ] `collectTurn` 超时显式报 `outcome=timeout`
- [ ] `handleAudio` 在写 iOS WS 失败时直接退出 session（不要再 try 80 次）
- [ ] warn 日志去重 / 采样
- [ ] `extractServerASRText` 已有，但要核对：即便 `outcome=timeout` 也要触发 badge emit 链路看是否需要

### 文档 / 复用

- [x] 本文（`docs/20_I20_voice_turn_boundary_pitfalls.md`）
- [x] `docs/13_ClientASR集成与使用指南.md`（顶部加 "B14 已废弃" 标注）
- [ ] `docs/24_voice_turn_timeout_contingency.md`（next batch）

---

## 7. 引用

- 后端：`internal/voicegateway/provider_volc_duplex.go` `collectTurn`、`HandleClientAudio`
- 后端：`internal/voicegateway/handler.go` `handleAudio` + warn 级联
- iOS：`Shared/FluentWorkCore/Architecture/Middleware/SpeechSessionMiddleware.swift`
- iOS：`Shared/FluentWorkCore/Services/LiveAudioEngine.swift`
- B13：`docs/22_B13_client_asr_回灌_实现说明.md`（实现说明）
- B14：本日 date 的 backend `provider_volc_duplex.go` B14 phase
