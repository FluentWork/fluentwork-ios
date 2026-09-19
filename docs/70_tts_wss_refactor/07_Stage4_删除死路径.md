# 07 — Stage 4 实现说明：删除死路径

> 对应 [`03_重构建议与迁移路径.md`](./03_重构建议与迁移路径.md) 的 Stage 4。
> 前置：[`06_Stage2_3_接线实现说明.md`](./06_Stage2_3_接线实现说明.md)（协调器接管音频分支）。
> 落地方式：**直接删除**（用户 2026-09-20 决定），而非仓库惯例的「先标记后删」；删除理由与替代物记录在本文件与该提交的信息里。

## 1. 删了什么，为什么它们是死的

> **修订（2026-09-20）**：下表的删除**有两行被撤销了**。`f3bb127`（引入麦克风替身）把 `TTSDecoder.swift` 与 `EngineBackedTTSDecoder.swift` 原样加了回来——不是复活接线，是那次提交顺带带回了这两个文件。它们现在**都在仓库里、都是零调用点**：`f3bb127` 之后没有任何生产代码引用 `TTSFrameDispatcher` / `TTSDecoder` / `EngineBackedTTSDecoder`。「删除」这个动作本身没有被推翻（旧路径确实没人走），被推翻的是「这两个文件已经不在了」这个事实。**当天第二次修订：已重新删除**（见下表末列）。

| 删除 | 行数 | 为什么 | 现状（2026-09-20 核对 HEAD `d004869`） |
|------|------|--------|--------------------------------------|
| `Shared/FluentWorkCore/Audio/TTSDecoder.swift` | 164 | `TTSFrameDispatcher`（`.idle` 漏帧 / `.draining` 认领不播）、`TTSDecoder` 协议、`TTSCodec`、`TTSCompletionStatus`、`TTSDecoderError` —— 接线后没有生产调用点 | **已重新删除**（2026-09-20）。删前核对：全仓零引用，仅剩两处墓碑注释 |
| `MockTTSDecoder.swift` | 55 | 只记录、不出声。**2026-09-12 静音事故的主角**：网关一发 `ai.tts.start`，帧被认领进它 | 仍已删除（全仓无此文件） |
| `EngineBackedTTSDecoder.swift` | 86 | 回滚后一直没接进 DI；它的形态（流式解码 → 引擎）已被「解码 seam + `AudioSink.play(pcm:)`」取代 | **已重新删除**（2026-09-20）。它的头部注释还在描述一个已不存在的世界（「网关从不发 `ai.tts.start`」） |
| `EngineAudioSink.swift` | 158 | Stage 0 抽出的播放器 actor，从未接线；`LiveAudioEngine` 自己就是 sink，两份「PCM → 缓冲 → 入队」留一份 | 仍已删除 |
| `ttsDecoder` DI 绑定（`AppDependencies.swift`） | — | 指向 Mock，已无读者。原位留注释说明它为什么曾经是雷，以及现在的回滚方式 | 仍已删除；原位注释已从 `:538-557` 移到 `:574-580` |
| `EngineBackedTTSDecoderTests.swift` | 102 | 随之删除 | 仍已删除 |

`AITTSFramesTests.swift` 的 8 条与 `AudioSinkTests.swift` 的 4 条一并删除，**意图**已迁到对的载体上
（逐条对应表见 `AITTSFramesTests.swift` 文件头与 `06` §3）。两条迁移是新增覆盖，不是平移：
`testAITTSAudio_BinaryLayoutIsSequenceThenPayload`（契约要求帧格式一个字节不改）与
`playPCMScheduling*`（缓冲不变量钉在真的会出声的引擎上）。

**测试数**：572 → 560（删 16，增 4）。

## 2. 双水印：只剩一道，另一道连同它的入口一起删了

> **修订（2026-09-20，第二次）**：本节在第一次修订里主张「`AudioPlaybackGate` 留着，因为
> 『没有调用点』与『可以删』不是同一件事」。那个主张**已被推翻**，而且推翻它的理由比原文
> 强得多：那道门不只是没有读者，它**不可能被武装**。它已随 `play(frame:)` 一起删除。

`03` 的 Stage 4 写着「删双水印之一（保留引擎侧，按轮重置）」。实际落地是：
旧派发器那一道随它自己的状态机一起消失；引擎侧 `AudioPlaybackGate` 当时原样保留，
理由是「`play(frame:)` 这个入口还在」。legacy 路线随 `d004869` 消失之后，那个入口也没有生产调用点了。

### 为什么可以删：它不是「没接线」，是「接不上」

第一次修订说「没有调用点 ≠ 可以删」。这句话本身没错，但它只问到「谁调用它」，
没问**那道门还能不能拦住东西**。答案是拦不住，而且原因是结构性的：

- `interruptWatermark` 的唯一赋值点是 `markInterrupted()`，它写的是 `lastAcceptedSequence`
- `lastAcceptedSequence` 的唯一赋值点是 `shouldAccept()` 内部
- `shouldAccept()` 的唯一调用点是 `play(frame:)`

`play(frame:)` 没有生产者 ⇒ 它永不执行 ⇒ `lastAcceptedSequence` 恒为 nil ⇒
`markInterrupted()` 恒把 watermark 置为 nil ⇒ `shouldAccept()` 恒放行。

也就是说：**即使今天有帧被路由到 `play(frame:)`，那道门也一个都不会拦。** 它是一段无法进入
自己失效状态的状态机。删它不是「删掉一个暂时没人用的保险」，是「删掉一个已经不可能起作用的东西」。

### 该保留的是另一道，而它一直很扎实

| | 引擎侧 `AudioPlaybackGate`（已删） | 传输层 `BargeInAudioGate`（保留） |
|---|---|---|
| 位置 | `LiveAudioEngine.play(frame:)` | `URLSessionSocketTransport.handle(message:)` 的 `.data` 分支 |
| 覆盖面 | 只有 legacy 入口 | **每一个**入站二进制帧——`handle(message:)` 只有 `receiveLoop` 一个调用者，没有旁路 |
| 武装 | 不可达（见上） | 有真实生产者：`DefaultSpeechSessionClient` 的 `submitTranscript("__interrupt__")` |
| 释放 | — | `ai.turn.end` |
| 上报 | 引擎事件（随之删除） | `SocketTransportDiagnostic.audioFrameDropped`，有真实消费者 |
| 测试 | 直接调门本身 | 驱动**真传输**（`SocketTransportTests` 用 `URLSessionSocketTransport()` 本身） |

今天 barge-in 的丢弃**只在传输层发生一次**。轮次归属由 `TTSPlaybackCoordinator` 在
正确的轴上回答：被作废那一轮的帧根本到不了引擎。

### 序列号说不出一个帧属于哪一轮

保留这段，是因为它是「序列水印」这条路走不通的**唯一书面记录**——原载体
（`FoundationComponentsTests.anInterruptDoesNotStopAudioThatHasNotArrivedYet`）已随
`AudioPlaybackGate` 一起删除，正文搬到这里：

> **2026-09-12 03:57 的复现。** 用户的场景，原话：
>
> tap 开始说话，让 AI 长答、TTS 正在播，中途再 tap 开始说话并讲话——右侧显示「正在转写」，
> 而**上一条**回复还在响，等它放完，它所属的那一轮已经明显走过去了。
>
> 设备日志把它钉死：
>
>   * turn-1 的 `ai.tts.end` 报 **`duration_ms: 61232`**——供应商花了 61 秒产出那条回复。
>   * 它的全部 **113** 个音频帧（`sequence` 500…612，每帧 3200 字节）在 **1.1 秒内**到达
>     客户端——`total_ms` 17327 → 18430。
>   * 所以头 ~60 秒里，那条回复**已经存在但还没被投递**。用户的 tap 落在这个窗口里。
>
> 于是 tap 在它所打断的音频到达**之前**就被处理了，而这正是水印门禁看不见的情况：
> `markInterrupted()` 记录的是**已被接受**的最高序号（≤499），而 500…612 全部**高于**它，
> 于是一个不剩地被接受并排进播放器。被打断的那一轮完整地播完，晚了大约一分钟。
>
> **这件事曾被错误地驳回一次。** 早先一版推理认为一个 burst 只有 6–48ms 宽、"而 tap 不是"，
> 所以门禁解释不了人手动触发的症状。那个推理只看 burst **到达**要多久，从没问它**等了**多久
> ——而这里的答案是 61 秒。窗口不是 burst，是「供应商做完」到「客户端拿到」之间的全部时间。
>
> **结论**：水印是一个**序号**水印，而序号说不出一个帧属于哪一轮。想用序号去归属轮次，
> 就会在这里失败。归属必须由轮次本身承载——这正是 `TTSPlaybackCoordinator` 按
> `ai.tts.start` / `ai.tts.end` 括起来的轮次做归属、而 `AudioPlaybackGate` 被删掉的原因。

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
- **音频**：**删除本身无行为变化**——被删的都是不可达代码（见 §2 的论证）。
- **回滚**：`git revert` 该提交即可恢复整条旧路径。

## 5. 同一轮的另外两件事，以及它们没有覆盖到的地方

本轮除了上面的删除，还做了两件：

1. **Stage 1 接线**（`02` §5 那次修订描述的重构真的发生了）：`TransportEventRouter`
   成为传输事件的真实分发点，中间件里那个 237 行的 switch 收敛成一行。
2. **删掉引擎侧的 `AudioPlaybackGate` 与 `play(frame:)`**（本文 §2）。

> **⚠️ 本轮只跑了 `swift test`，没有做真机验证。**
>
> 删除那部分不需要真机——被删的代码不可达，这在上面是论证过的。**但接线那部分不是**：
> 它改的是活的 dispatch 路径，而这条链路的失败模式历来是「转写正常、没有声音」，
> 单测两侧全绿也照样发生过（2026-09-12 静音事故、2026-09-20 的 start 顺序缺陷）。
>
> 真机验证另开一轮，按整合后的 backend `docs/101_` 与本文档目录的
> [`09_麦克风替身.md`](./09_麦克风替身.md) 跑，重点两条：
> **barge-in（打断后上一轮的尾音不得混进下一轮）** 与 **断线重连（序号不回退、还有声）**。
> 在那一轮通过之前，本文档描述的接线状态应视为「单测已验、真机未验」。
