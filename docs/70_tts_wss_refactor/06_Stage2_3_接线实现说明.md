# 06 — Stage 2/3 接线实现说明：协调器接管音频分支

> 对应 [`03_重构建议与迁移路径.md`](./03_重构建议与迁移路径.md) 的 Stage 2（接线）与 Stage 3 的 **iOS 侧那一半**。
> 前置：[`05_Stage2_实现说明.md`](./05_Stage2_实现说明.md)（组件本身）。

## 0. 一句话

下行音频现在只有一个入口：`ai.tts.start` 决定归属，`TTSPlaybackCoordinator` 决定播/丢，
`AudioEngine` 自己当 sink 去播。

> **修订（2026-09-20）**：原文接着说「**今天的行为与接线前逐字节相同**，因为网关还没发 `ai.tts.start`；网关一旦开始发，音频不会再被认领进一台录音机」。后半句的预判已经应验（网关确实开始发，音频确实没进录音机）；**前半句已经过时**——网关现在总是发 `ai.tts.start`（后端 `3cb3774`，顺序由 `afe5eb5` 修正为首帧音频之前、每轮一次），所以「所有帧都走 legacy」不再是今天的形状。接线时那个「零行为变化」是**接线当天的**事实，不是现在的事实。

## 1. Stage 2 和 Stage 3 的 iOS 侧为什么合成一个提交

拆不开。接线的**唯一出口**就是「解码后的 PCM 交给 sink」：没有真实 decoder 就没法接线，
所以「接线」与「换上会出声的解码器」是同一个动作的两面。Stage 3 的另一半（网关开始发
`ai.tts.start`）**不在本仓**，按契约 `meta 83_` §2 的顺序（客户端先、网关后）应当在这次
提交真机验证之后再做。

## 2. 三个关键决定

### 2.1 让引擎自己当 sink，而不是换一个对象去播

`AudioEngineProtocol: AudioSink`，`TTSPlaybackCoordinator` 的 `sink` 就是 `audioEngine`。

理由是接线时最容易漏的一处：`LiveAudioEngine.play(frame:)` 上有两个守卫 ——
`AudioPlaybackGate`（barge-in 序列水位线）与 `playbackRetired`（会话收尾后不再复活播放）。
换成 `EngineAudioSink` 去播会**静默绕过这两个守卫**，症状分别是「打断后接着响」和
「结束练习后又被迟到帧拉起来」。引擎即 sink，守卫就留在原地，legacy 路径逐字节等价。

### 2.2 归属指针在打断时**不**移动（`.draining` 的等价物）

线上二进制帧不带 `turn_id`（契约 `83_` §1：格式不变），归属由「谁在 start 与 end 之间」决定。
所以裸帧入口按归属指针解析轮次，而打断**只**把该轮标记为作废、**不清空指针**：

```
打断 → 该轮 .superseded（指针仍指着它）
     → 之后到达的帧：解析到该轮 → 丢弃     ← 旧的 `.draining`
     → ai.tts.end 到达 → 注销 + 清指针
```

指针若在打断时清空，这批帧会「因为没有活跃轮次」退回 legacy 被播出去 —— 那就是
「用户打断了，上一轮接着说」。旧派发器的第二个出口（下一个 start 结束卡住的 draining）
也保留了：`onStart` 会把上一轮标为作废。

### 2.3 keyed 帧不走序列水位线

`play(pcm:)` 有意不查 `AudioPlaybackGate`：那道门是**按序列号**判「是否在打断水位线之下」，
而 keyed 帧没有序列号可用。它回答的问题（「这一帧还属于当前这轮吗」）在轮次这条轴上由
协调器回答得更准 —— 水位线判不了「打断后才到达的迟到帧」（它们序列号更高，
`theWatermarkIsASequenceAndNotATurnBoundary` 已经把这个事实钉住）。

结果是两条路径各有一道门：legacy 帧归水位线，keyed 帧归轮次注册表。

> **修订（2026-09-20）**：「两条路径各有一道门」这句话已经不成立了——legacy 那条路随 `d004869` 删除（`play(legacy:)` 没了，无归属的帧直接丢弃），今天只剩轮次注册表这一道门在管真实音频。原文给水位线留存的理由是「契约要求 legacy 回滚能力长期存在（网关停发 start 即退回 fallback）」，**这个 fallback 已经不在了**，所以那条理由作废；水位线仍在是因为 `AudioPlaybackGate` 还是 `play(frame:)` 的守卫（理由详见 `07` §2 的同一条修订）。删它不在本次修订的范围里。

## 3. 测试迁移：旧测试的名字本身就是那个 bug

| 旧测试 | 新测试 | 为什么 |
|--------|--------|--------|
| `speechSessionMiddlewareRoutesTTSFramesToMockDecoderNotAudioEngine` | `startClaimedTTSFramesReachTheEngineAsSound` | 旧名字断言「认领进只记录的解码器、不碰引擎」—— 那正是静音事故的形状 |
| `speechSessionMiddlewareResetsTTSDispatcherOnEndWithoutTTSEndFrame` | `leftoverTTSStartDoesNotClaimTheNextSessionsFrames` | 解码器无状态了，要清的是**归属**；断言从「补了一个 finish」变成「残留 start 不吞下一场」 |
| `ttsStreamEmitsStartFirstAudioAndEndViaSharedTracker` | 同名，改为断言 PCM 到达播放口 | 原来只看 tracker 事件，现在同时钉住「真的解码出声」 |

改之前，第一个测试的真实失败输出（旧契约在新实现下崩掉的样子）：

```
✘ Test speechSessionMiddlewareRoutesTTSFramesToMockDecoderNotAudioEngine() recorded an issue
  at SpeakingRoomSessionWiringTests.swift:573:5: Expectation failed: decoder.snapshotFeeds().map(\.seq) == [0, 1]
✘ Test speechSessionMiddlewareRoutesTTSFramesToMockDecoderNotAudioEngine() recorded an issue
  at SpeakingRoomSessionWiringTests.swift:575:5: Expectation failed: decoder.snapshotFinishes().map(\.status) == ["ok"]
```

## 4. 红验证（破坏实现 → 确认重新红）

| 破坏方式 | 结果（实际输出） |
|---------|-----------------|
| 打断时清空归属指针 | ✘ `bareFrameBetweenInterruptAndEndIsDropped`：`outcome == .dropped(...reason: .superseded...)`、`sink.legacyPlayCalls.isEmpty` |
| 裸帧入口永远走 legacy | ✘ `startClaimedTTSFramesReachTheEngineAsSound`：`audioEngine.snapshotPlayedPCM() == [first.payload, second.payload]`、`snapshotPlayedFrames() == [beforeStart]` |
| 会话收尾不 reset | ✘ `leftoverTTSStartDoesNotClaimTheNextSessionsFrames`：`snapshotPlayedFrames() == [frame]`、`snapshotPlayedPCM().isEmpty` |

三条都红在预期断言上，破坏后源码已还原（`diff` 校验一致）。

全量：`swift test` **572/572 通过**；`swift build --build-tests` 通过。

## 5. 顺带删掉的一件假能力

`AudioSink.drain()` 被移除。它在三个实现里都是 no-op，没有任何生产调用点，唯一的作用是
让「引擎能优雅等播完」看起来像契约的一部分 —— 而 `AVAudioPlayerNode` 根本没有同步等待 API。
一个从不做事的协议要求比没有这个要求更危险。

## 6. 影响面与未完成项

- **接线当时的行为**：零变化。网关当时还不发 `ai.tts.start`，所有帧走 legacy。
- **网关打开 start 之后**：帧按轮归属，解码走 `WSAudioFrameDecoderAdapter`（复用
  `wsAudioFrameDecoder` 这个工厂 —— 一个 codec 实现，两个调用点）。**这条已经发生**：网关总是
  发 `ai.tts.start`（后端 `3cb3774`/`afe5eb5`），keyed 路径是今天唯一在用的路径。
  **修订（2026-09-20）**：原文这里还写着「`play(legacy:)` 默认实现就是 `play(frame:)`」——
  那条默认实现和 legacy 路径本身都在 `d004869` 删掉了。
- **观测**：新增 `tts_frame_dropped`（reason∈{superseded, unknownTurn}）埋点。丢弃从此有日志；
  `tts_decoder_failed` 保留，语义收窄为「解码失败」。
- **未完成**（原文列的这三项，2026-09-20 全部关闭，逐项对账）：① 真机 smoke（出声、打断不串音、首响）—— 已做，见 `08`；但其中「打断后在途帧被丢弃」的**端到端**证据仍缺（`08` §3 写明：250 帧一次性突发送达，没有在途帧可丢），这一半至今只有单元层证据。② 网关开始发 `ai.tts.start`（另一仓，按契约 §2 在①之后）—— 已发（后端 `3cb3774`），但顺序出过错（start 落在它引出的音频之后，症状正是静音），由 `afe5eb5` 修正为「首帧音频之前、每轮一次」；这一段见后端 devnotes `2026-09-20-start-after-audio-and-gated-state-machine.md`。③ Stage 4 删死路径 —— 已做（`e64237e`），随后 `d004869` 又删掉了 legacy 回退本身；注意 `f3bb127` 把其中两个文件加了回来，见 `07` 的修订注。
