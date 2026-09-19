# 07 — Stage 4 实现说明：删除死路径

> 对应 [`03_重构建议与迁移路径.md`](./03_重构建议与迁移路径.md) 的 Stage 4。
> 前置：[`06_Stage2_3_接线实现说明.md`](./06_Stage2_3_接线实现说明.md)（协调器接管音频分支）。
> 落地方式：**直接删除**（用户 2026-09-20 决定），而非仓库惯例的「先标记后删」；删除理由与替代物记录在本文件与该提交的信息里。

## 1. 删了什么，为什么它们是死的

| 删除 | 行数 | 为什么 |
|------|------|--------|
| `Shared/FluentWorkCore/Audio/TTSDecoder.swift` | 164 | `TTSFrameDispatcher`（`.idle` 漏帧 / `.draining` 认领不播）、`TTSDecoder` 协议、`TTSCodec`、`TTSCompletionStatus`、`TTSDecoderError` —— 接线后没有生产调用点 |
| `MockTTSDecoder.swift` | 55 | 只记录、不出声。**2026-09-12 静音事故的主角**：网关一发 `ai.tts.start`，帧被认领进它 |
| `EngineBackedTTSDecoder.swift` | 86 | 回滚后一直没接进 DI；它的形态（流式解码 → 引擎）已被「解码 seam + `AudioSink.play(pcm:)`」取代 |
| `EngineAudioSink.swift` | 158 | Stage 0 抽出的播放器 actor，从未接线；`LiveAudioEngine` 自己就是 sink，两份「PCM → 缓冲 → 入队」留一份 |
| `ttsDecoder` DI 绑定（`AppDependencies.swift`） | — | 指向 Mock，已无读者。原位留注释说明它为什么曾经是雷，以及现在的回滚方式 |
| `EngineBackedTTSDecoderTests.swift` | 102 | 随之删除 |

`AITTSFramesTests.swift` 的 8 条与 `AudioSinkTests.swift` 的 4 条一并删除，**意图**已迁到对的载体上
（逐条对应表见 `AITTSFramesTests.swift` 文件头与 `06` §3）。两条迁移是新增覆盖，不是平移：
`testAITTSAudio_BinaryLayoutIsSequenceThenPayload`（契约要求帧格式一个字节不改）与
`playPCMScheduling*`（缓冲不变量钉在真的会出声的引擎上）。

**测试数**：572 → 560（删 16，增 4）。

## 2. 双水印：收敛成了一道，但不是删出来的

`03` 的 Stage 4 写着「删双水印之一（保留引擎侧，按轮重置）」。实际落地是：
**旧派发器那一道随它自己的状态机一起消失**，引擎侧 `AudioPlaybackGate` 原样保留。
现在两条路径各有一道门 —— legacy 帧归序列水位线，keyed 帧归轮次注册表。

水位线**不能删**：契约 `meta 83_` §2 的回滚方式就是「网关停发 `ai.tts.start`，客户端退回
legacy」，只要 fallback 还要活着，它的守卫就得在。

## 3. 一条已知缺口（不在本次范围，建议下一步处理）

`ai.tts.start` 带 `codec` 字段，但客户端**不看它**：`RawPCM16FrameDecoder` 一律把 payload
当 PCM16。合同草案 `83_` §4.1 明确网关应填 `pcm`，所以今天是对的；但如果后端先切到 Opus
（B13）而客户端绑定还没换，音频会被当成 PCM16 播放 —— 症状是**噪音，不是静音**，
而噪音比静音更容易被误判成「设备问题」。

建议的下一步（独立小改动）：让解码 seam 声明它承载的 codec，`onStart` 携带 codec，
不匹配时按一轮作废处理并埋点。本次不做，是因为它需要一个新的失败语义，值得单独定。

## 4. 影响面

- **状态机**：无影响。
- **协议**：无影响（本次只删客户端死代码）。
- **音频**：无行为变化。被删的都是无调用点代码；legacy 与 keyed 两条路径都不经过它们。
- **回滚**：`git revert` 该提交即可恢复整条旧路径。
