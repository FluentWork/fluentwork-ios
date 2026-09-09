# T-I20-4 turn 埋点与 TTS 追踪日志

**票**：I20 T-I20-4
**状态**：已落地。

## 1. 要守住的原理

I20 的 60s 录音 abort 和 B15 的 70s processing timeout 必须是两条 tracker 事件，不能合成一个 `turn.timeout`。

- 录音 abort → `turn.timeout`（`elapsed_ms=60000`）+ `turn.outcome`（`timeout`）
- 正常说完 → 只有 `turn.outcome=ok`，没有 `turn.timeout`
- 放弃 / 失败 abort → `turn.outcome=user_abandoned|error`，没有 `turn.timeout`
- B15 70s 仍用既有 `turn_timeout_fired`

TTS 成功路径也要能追踪。失败已有 `tts_decoder_failed`；本票补 start / 首包 / end，不逐包打点。

## 2. 根因

T-I20-1/2 有 abort 帧和 `TurnOutcome`，但 tracker 只有 `timing_recording_turn_abort` 和 B15 的 `turn_timeout_fired`，无法按 outcome 分布检索，也容易把 60s abort 误当成 70s 会话失败。

TTS 侧只有 decoder 失败日志。`ai.tts.start` / 首包 / `ai.tts.end` 成功时几乎看不见，联调只能靠 DEBUG `transport_rx`。

## 3. 方案

事件（`TrackerClientProtocol.track`，不是票面里的 `Tracker.shared.log`）：

- `turn.timeout` — `session_id`, `turn_id`, `elapsed_ms`
- `turn.outcome` — `outcome`, `session_id`, `turn_id`
- `tts_start` — `turn_id`, `voice_id`, `sample_rate`, `codec`
- `tts_first_audio` — `turn_id`, `sequence`, `payload_bytes`（每个流只一次）
- `tts_end` — `turn_id`, `completion_status`, `duration_ms`, `audio_frames`
- `tts_interrupt` — barge-in 停播时的 `turn_id`

`tts_end.audio_frames` 用 `TTSStreamTrace` 计数，避免每条 Opus 都打 tracker。

### 3.1 埋点接发走 middleware 的 Container（缺省 `Container.shared`）

生产路径：

1. `speechSessionMiddleware` 入参是 `Container?`。未注入时解析为 **`Container.shared`**。
2. 埋点一律 `container.tracker().track(...)`，session_id 一律 `container.speechSessionClient().activeSessionID()`。和 `audioEngine` 同一份容器，不要另开 `Container()`，也不要走票面里的 `Tracker.shared.log`。
3. abort 的 `turn.timeout` / `turn.outcome` 必须在 `.endSession` 取消 Task 之前同步发出。`ok` 可以跟在 VAD `speechEnded` 之后异步发。

`tracker` 在 `AppDependencies` 上是 **`.shared`（每容器一份）**，和 `speechSessionClient` 同类，**不是** `.singleton`。生产只有一份 `Container.shared`，进程内仍是一个 ConsoleTracker。

测试路径（与 B14 middleware 用例同一套本地容器）：

1. `let container = Container()`，在**这一份**上 `audioEngine` / `speechSessionClient` / `tracker.register`，再 `AppStoreFactory.make(container:)`。
2. 不要去 `Container.shared.reset()` 抢进程单例。并行测试互相 reset 会把 stub 冲掉，`recordingTimeout` 一类用例会卡在 VAD。
3. 只验 decoder 路由、不验 tracker 的用例同样用本地 `Container()`（`ttsDecoder` 是 `.unique`）。

对照：`logger` / `secureStorage` 仍是 `.singleton`。那一类若要断言，才需要 `Container.shared` + suite `.serialized`。tracker 不在那一类里。

## 4. 为何不折进现有路径

- 不复用 `turn_timeout_fired`：那是杀会话的 B15 路径
- 不把 TTS 日志塞进 `timing_ai_first_chunk`：那条对所有 AI 音频帧都 mark，且没有 turn_id
- 不逐包 `tts_audio`：16k 流会淹没真正的 start/end

## 5. 影响面

状态机 / WSS 线格式不变。只增加 tracker 事件。音频播放路径不变。

## 6. 测试

断言走注入 Container 的 suite：`I20TurnTelemetryTests`。

`swift test --filter "I20 turn telemetry|SpeechSessionPrompt|RoutesTTSFrames"`
