# iOS TTS/WSS 架构审核与重构 — 系列文档

> 作者视角：资深 iOS 开发专家。审核对象：`fluentwork-ios` 的 TTS（文本转语音）与 WSS（WebSocket）链路。
> 触发条件：当前这条链路「能出声」是一个巧合，而不是设计的结果。

## 一句话结论

iOS 的 AI 语音回放有**两条并行的播放路径**，而 app 之所以还能出声，是因为这两条路径之间恰好踩中了一个「网关不发 `ai.tts.start`」的偶然事实：

- **设计路径（A）**：`ai.tts.start` → `TTSFrameDispatcher` 进入 `.active` → 后续二进制帧被 `handle(audio:)` 认领 → 交给 `TTSDecoder` 解码播放。
- **实际路径（B）**：网关不发 `ai.tts.start`，`TTSFrameDispatcher` 永远停在 `.idle`，`handle(audio:)` 返回 `false`，帧「漏」到 `audioEngine.play(frame:)` 直接播。

而生产环境 DI 绑定的 `TTSDecoder` 是 `MockTTSDecoder`（**只记录、不出声**）。也就是说：**一旦网关开始发 `ai.tts.start`（而这恰恰是给二进制帧赋予「轮次归属」、从而能在打断时丢弃 in-flight 音频的前提），音频会被路由到一台录音机，变成静音。** 这条 2026-09-12 已经踩过一次并回滚（`AppDependencies.swift:538-557`）。

这是整条链路的病根。所有其他问题（无轮次归属、双解码器、双水印门禁、巨石中间件）都是它的症状或帮凶。

## 文档索引（按阅读顺序）

| # | 文档 | 回答的问题 |
|---|------|-----------|
| 1 | [`01_现状架构审计.md`](./01_现状架构审计.md) | 现在到底是什么样的？哪两条路径？问题清单和根因链 |
| 2 | [`02_目标架构与组件设计.md`](./02_目标架构与组件设计.md) | 如果我从零实现这个组件，会怎么设计？ |
| 3 | [`03_重构建议与迁移路径.md`](./03_重构建议与迁移路径.md) | 不动架构大换血，如何一步步把现状改到目标？ |
| 4 | [`04_从测试出发.md`](./04_从测试出发.md) | 每个重构步骤由哪条「先红」的测试驱动？ |
| 5 | [`05_Stage2_实现说明.md`](./05_Stage2_实现说明.md) | Stage 2 的协调器落地了什么、红验证证据、还有什么没接 |
| 6 | [`06_Stage2_3_接线实现说明.md`](./06_Stage2_3_接线实现说明.md) | 协调器接管音频分支：三个关键决定、测试迁移、红验证 |
| 7 | [`07_Stage4_删除死路径.md`](./07_Stage4_删除死路径.md) | 删掉了哪条并行路径、为什么水位线不能删、剩下的一条缺口 |
| 8 | [`08_真机验证记录_2026-09-20.md`](./08_真机验证记录_2026-09-20.md) | 真机验到了什么、没验到什么、与后端 `93_` 梯子契约的逐条核对 |

## 与既有文档/台账的对应关系

| 本文档 | 关联的外部依据 |
|--------|---------------|
| 现状审计 | `meta docs/40_研发流程与协作/77_待修复问题总清单`（P0-11 等） |
| 轮次归属契约 | `meta docs/30_技术方案/82_打断后音频归属_契约草案`、`83_轮次归属_方向A契约草案` |
| 回滚复盘 | `meta docs/30_技术方案/84_打断这件事为什么看着别扭_复盘` |
| 红验证纪律 | `meta docs/40_研发流程与协作/78_会话交接与下一步` §五 |

## 阅读前提

默认读者已了解：`SpeechSessionMachine`（纯状态机）、`SpeechSessionMiddleware`（副作用解释）、`URLSessionSocketTransport`（WSS 传输）、`LiveAudioEngine`（AVAudioEngine 采集 + 播放）、FactoryKit DI。若不清楚，先读 `fluentwork-ios/CLAUDE.md`。

## 关键代码位置速查

| 组件 | 文件:行 |
|------|---------|
| `TTSFrameDispatcher`（状态机 + 双路径分叉点） | `Shared/FluentWorkCore/Audio/TTSDecoder.swift` |
| `MockTTSDecoder`（生产绑定、只记录） | `Shared/FluentWorkCore/Audio/MockTTSDecoder.swift` |
| `EngineBackedTTSDecoder`（已写已测、被回滚） | `Shared/FluentWorkCore/Audio/EngineBackedTTSDecoder.swift` |
| 生产 DI 绑定（rollback 注释） | `Shared/FluentWorkCore/Dependencies/AppDependencies.swift:538-557` |
| 双路径路由点（`consumedByTTS` 分支） | `Shared/FluentWorkCore/Architecture/Middleware/SpeechSessionMiddleware.swift:646-691` |
| `WSAudioFrame`（只有 seq、无 turn_id） | `Shared/FluentWorkNetworking/Socket/WSAudioFrameCodec.swift` |
| `WSAudioFrameDecoder` / `RawPCM16FrameDecoder` | `Shared/FluentWorkCore/Dependencies/AppDependencies.swift:123-162` |
| `LiveAudioEngine.play(frame:)` + `AudioPlaybackGate` | `Shared/FluentWorkCore/Services/LiveAudioEngine.swift` |
