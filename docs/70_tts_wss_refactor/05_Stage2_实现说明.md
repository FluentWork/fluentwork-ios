# 05 — Stage 2 实现说明：`TTSPlaybackCoordinator`

> 对应 [`03_重构建议与迁移路径.md`](./03_重构建议与迁移路径.md) 的 Stage 2，测试依据 [`04_从测试出发.md`](./04_从测试出发.md) §3.3。
> 状态：**组件已落地、已测试、已接入生产路径**。原文写「尚未接入生产路径」——那是写本节时的状态；接线发生在 `06` 那次提交（`SpeechSessionMiddleware.swift:76` 构造协调器，`:674`/`:703`/`:717` 三个 case 调用它），`08` 有真机验证记录。下文各处另有修订注。

## 1. 这一步在守什么契约

三条不变量，按重要性排序：

1. **被打断的轮次不再出声**（P0-11 根因）。用户 barge-in 之后，后端仍会把上一轮的残留帧推完；这些帧必须被丢弃，而不是排队播出去。
2. **带 `turn_id` 的帧必须经过真实解码 seam 才能到达 sink**。2026-09-12 的静音事故是「`ai.tts.start` 一旦出现，帧被派发器认领、路由进一台只记录的 `MockTTSDecoder`」。这条契约就是那根保险丝。
3. **没有 `turn_id` 的帧行为零变化**。后端改造完成前（Stage 3），所有真实帧都走 legacy 透传，与今天的 `audioEngine.play(frame:)` 等价。

> **修订（2026-09-20）**：第三条**被反向执行**，是这三条里唯一被推翻的一条。落地版对无归属的帧是**丢弃**（`.dropped(reason: .unknownTurn)`，`TTSPlaybackCoordinator.swift:136-143`、`:154-156`），不是 legacy 透传。它之所以能被这样改，是因为前提变了：网关不再处在「改造完成前」——它总是发 `ai.tts.start`（后端 `3cb3774`，顺序由 `afe5eb5` 修正为首帧音频之前），所以「所有真实帧都是无归属帧」这句今天为假。前两条不变量原样成立，且已被真机验证（`08`）。

## 2. 方案与归属文件

| 文件 | 职责 |
|------|------|
| `Shared/FluentWorkCore/TTS/TurnKeyedAudioFrame.swift` | 帧的**类型**：`turnID: String?` + `sequence` + `payload` |
| `Shared/FluentWorkCore/TTS/AudioFrameDecoder.swift` | 唯一的解码 seam：`TurnKeyedAudioFrame → 16k mono PCM16` |
| `Shared/FluentWorkCore/TTS/TTSPlaybackCoordinator.swift` | 决策：**播什么、丢什么** |
| `Shared/FluentWorkCore/Audio/AudioSink.swift` | 动作：`play(pcm:)` / `interruptNow()`（修订：`play(legacy:)` 随 `d004869` 删除，`drain()` 在 `06` §5 作为假能力删除） |
| `Tests/FluentWorkCoreTests/TTS/TTSPlaybackCoordinatorTests.swift` | 10 条测试锁住上述三条不变量 |

协调器本身是 `actor`，只持有一张 `turn_id → TurnState` 注册表和两个注入依赖（decoder、sink）。**它不认识 `AVAudioEngine`，也不认识 WebSocket**——这正是 Stage 0 先把播放抽象成 sink 的目的。

## 3. 两个关键设计点

### 3.1 「决策」与「动作」分离

`TTSPlaybackCoordinator` 里没有一行音频代码：它只决定**放行还是丢弃**，然后把活干交给 `AudioSink`。于是「播/丢」这件事第一次可以在 `swift test` 里被断言（`RecordingSink` 记录调用），而不必真机盲改——这是 01 §「静音测不到」那条教训的直接对策。

### 3.2 路由表是显式的四分支，不是「漏帧」

```
turnID == nil        → 丢弃（.unknownTurn）   ← 落地版；原写 legacy 透传
turnID 已注册 .active → 解码 → sink.play(pcm:)
turnID .superseded   → 丢弃
turnID 未知          → 丢弃（.unknownTurn）   ← 落地版；原写的可配 playAsLegacy 未实现
```

> **修订（2026-09-20）**：第一行与第四行都变了，两处都是「把可选项收成一条路」。legacy 透传随 `d004869` 消失；`unknownTurnPolicy` 这个配置项没有实现，兜底只剩丢弃。下面的论述前半句（「未知 turn_id」这一支是显式的、是查表而非侥幸）仍然成立，后半句（策略可配）不成立。

`onStart` 会自动 supersede 前一轮（后端可能不显式发 interrupt 就开新轮）。**「未知 turn_id」这一支是显式的**：今天 `TTSFrameDispatcher` 停在 `.idle` 时返回 `false`、帧「漏」到引擎直接播，是一个偶然；这里是查表后的有意决策。

同一轮内的帧**不重排**：下行帧按到达顺序进入，乱序重排不在本组件职责内（目标设计里也没有）。

## 4. 红验证

本轮是**新增能力**（尚无失败的既有状态），按 AGENTS.md 的例外条款固定预期行为，并额外做了「破坏实现 → 确认测试重新红」：

| 破坏方式 | 结果 |
|---------|------|
| 旁路真实 decoder（直接 `sink.play(pcm: frame.payload)`） | ✘ `start 认领的帧经 decoder 解码后到达 sink`：`Expectation failed: decoded.count == 1` |
| 删掉 superseded 闸门 | ✘ `被打断的轮次的迟到帧不播放`：`playCalls.count == 1`；✘ `新轮次启动会立即 supersede 旧轮次` |
| 静音 legacy 路径 | ✘ `无 turn_id 的帧走 legacy 路径`、`有 turn_id 和无 turn_id 的帧不交错`、`未知 turn_id 用 playAsLegacy 策略时透传` |

第一行即 `04` §5 点名要求的那条：把真实 decoder 换成旁路，保险丝必须断。

**当下全量**：`swift test` 564/564 通过；`swift build --build-tests` 通过。

## 5. 未完成项（不属于本提交）

1. **尚未接线**：`TTSPlaybackCoordinator` 目前没有任何生产调用点。让它接上 `TransportEventRouter` 的音频分支是一次**行为改动**（即便初期全部走 legacy 透传），按 `03` 的风险表需要在真机上确认「出声正常 + 打断不串音」后再落地。
2. `WSAudioFrame` 仍无 `turn_id` 字段——Stage 3 才由后端补；在此之前所有帧的 `turnID` 都是 `nil`。
3. 解码失败目前静默丢弃；埋点（`tts_decoder_failed`）留给 caller（middleware）承担。

## 6. 影响面

- **状态机**：无影响。协调器不进入 `SpeechSessionState`。
- **协议**：无影响。`TurnKeyedAudioFrame` 是纯客户端类型，`turn_id` 还是可空。
- **音频**：无影响（未接线）。接线后 legacy 帧会多一次 actor hop。
- **发布**：无影响，无新 flag。
