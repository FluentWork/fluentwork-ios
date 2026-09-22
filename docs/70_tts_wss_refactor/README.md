# iOS TTS/WSS 架构审核与重构 — 系列文档

> 作者视角：资深 iOS 开发专家。审核对象：`fluentwork-ios` 的 TTS（文本转语音）与 WSS（WebSocket）链路。
> 触发条件：当前这条链路「能出声」是一个巧合，而不是设计的结果。

## 一句话结论

> **修订（2026-09-20）**：本节原结论与本段相反 —— 它说 app 能出声是因为网关**不发** `ai.tts.start`、帧从派发器「漏」到 `audioEngine.play(frame:)`。那个前提、那条旁路、以及那个「生产绑了一台录音机」的雷，现在三者都不在了。原文收在文末「修订记录」里，此处按现状重写。

这条链路的「能出声」曾经是巧合：网关不发 `ai.tts.start`，帧从派发器漏出去、落到 `audioEngine.play(frame:)` 直接播。**巧合由两侧同时结束**：

- **网关总是发 `ai.tts.start`**（后端 `3cb3774`），且自 `afe5eb5` 起它在**首帧音频之前**发出、每轮恰好一次；被打断的轮拿到的是 `ai.tts.end`，没有 start。
- **iOS 删掉了 legacy 回退**（`d004869`）：`play(legacy:)` 已从 `AudioSink` 删除，`onAudioFrame` 在归属指针为空时直接返回 `.dropped(reason: .unknownTurn)`，无主的帧被丢弃（`TTSPlaybackCoordinator.swift:136-143`）。

于是「轮次归属」从一件碰运气的事变成了**硬要求**：没有 `ai.tts.start` 的帧不会被任何人认领，也不会退到任何备用路径——结果就是**静音**。今天之所以有声音，是因为设计路径成了唯一路径，而不是因为它旁边还留着一条会漏的旁路。

这同时改写了回滚手册：契约 `meta 83_` §2 那条「网关停发 `ai.tts.start`，客户端自动退回 legacy，不用改任何一行」，**已经没有对应的实现**。停发 start 现在的含义是整轮静音，不是「换一条路出声」；要回滚只能回滚客户端提交。

旧结论里那句「这是整条链路的病根」仍然成立，只是病根已经治了：**无轮次归属**（P-B）不再是问题，归属现在是显式查表；**双解码器**（P-C）的语义冲突也解除了 —— 生产绑定的解码 seam 只有 `RawPCM16FrameDecoder` 一条实现。

> **修订（2026-09-20，第二次）**：下面这一段里关于水印与中间件的两句，在本轮之后只剩一句仍然成立。

**双水印门禁（P-D）已经收敛成一道**（2026-09-20）。引擎侧那道 `AudioPlaybackGate` 连同它的入口 `play(frame:)` 一起删除了——它不只是没有读者，而是**不可能被武装**：watermark 的唯一赋值点写的是 `lastAcceptedSequence`，而后者只在 `shouldAccept` 内写，`shouldAccept` 的唯一调用点又是永不执行的 `play(frame:)`。证据链与 2026-09-12 03:57 那段原始记录见 [`07`](./07_Stage4_删除死路径.md) §2。今天 barge-in 的丢弃**只在传输层发生一次**（`BargeInAudioGate`）。

**巨石中间件（P-E）原封未动**——这一条仍然成立，而且现在有准确数字：路由只占它 1470 行里的约 275 行（19%），拆出去的只是那个 switch 壳；`audioEventPump`（209 行）仍是第二个大 switch，`TransportEventRouter` 不覆盖它。

另外 P-G 那根 `EngineBackedTTSDecoder` 的 AsyncStream 单消费者桥，文件被 `f3bb127` 加回来过、**本轮已再次删除**（`07` §1）。

## 文档索引（按阅读顺序）

| # | 文档 | 回答的问题 | 状态（2026-09-20 核对） |
|---|------|-----------|------------------------|
| 1 | [`01_现状架构审计.md`](./01_现状架构审计.md) | 现在到底是什么样的？哪两条路径？问题清单和根因链 | 历史快照（Stage 2/3 之前的现状），已被推翻，文首有注 |
| 2 | [`02_目标架构与组件设计.md`](./02_目标架构与组件设计.md) | 如果我从零实现这个组件，会怎么设计？ | **§5 的 Stage 1 已落地**（形状与原设计不同，见该节）；其余部分部分落地、部分改道 |
| 3 | [`03_重构建议与迁移路径.md`](./03_重构建议与迁移路径.md) | 不动架构大换血，如何一步步把现状改到目标？ | 计划，S0/S1/S2/S4 落地、S3 未走，文首有注 |
| 4 | [`04_从测试出发.md`](./04_从测试出发.md) | 每个重构步骤由哪条「先红」的测试驱动？ | 计划，T2c 未保留，文首有注 |
| 5 | [`05_Stage2_实现说明.md`](./05_Stage2_实现说明.md) | Stage 2 的协调器落地了什么、红验证证据、还有什么没接 | 实施记录，已接线，文中四处已修订 |
| 6 | [`06_Stage2_3_接线实现说明.md`](./06_Stage2_3_接线实现说明.md) | 协调器接管音频分支：三个关键决定、测试迁移、红验证 | 实施记录，文中四处已修订 |
| 7 | [`07_Stage4_删除死路径.md`](./07_Stage4_删除死路径.md) | 删掉了哪条并行路径、为什么水位线能删、剩下的一条缺口 | 实施记录；§2 已重写（引擎水印与其入口已删），§5 记本轮范围 |
| 8 | [`08_真机验证记录_2026-09-20.md`](./08_真机验证记录_2026-09-20.md) | 真机验到了什么、没验到什么、与后端 `93_` 梯子契约的逐条核对 | 日期快照，§4/§5.2 各有一条被后续提交推翻 |
| 9 | [`09_麦克风替身.md`](./09_麦克风替身.md) | `FW_MOCK_MIC`：真机验证不再依赖真麦克风（接管哪三处、替不掉什么） | 现行 |
| 10 | [`10_事实基线与缺陷清单.md`](./10_事实基线与缺陷清单.md) | 从代码读到的协议/音频/序号事实是什么？有哪 11 条缺陷、证据与确定性各是什么？ | 现行（基线 @ `00c182f`；**D5 已于 2026-09-22 修订**，两处立论被推翻，见 `13_` §7） |
| 11 | [`11_两方案评审与决策.md`](./11_两方案评审与决策.md) | 两个设计分支能不能作为施工依据？最终决策是什么？ | 现行（评审结论） |
| 12 | [`12_D1_首块音频判定顺序修正.md`](./12_D1_首块音频判定顺序修正.md) | D1：被丢弃的音频帧为什么会宣告「AI 开始说话」？根因、改法与红在哪 | 实施记录（`0436c27`；`swift test` 580/580） |
| 13 | [`13_缺必需字段的解码失败要点名字段.md`](./13_缺必需字段的解码失败要点名字段.md) | 缺必需字段的致命解码失败为什么说不出字段名？D5 为什么需要重判 | 实施记录（`swift test` 582/582）；**D5 的失败策略选择待定** |
| 14 | [`14_D3_一次打断只发一次interrupt.md`](./14_D3_一次打断只发一次interrupt.md) | D3：一次 barge-in 为什么发两次 `interrupt`、第二次为什么必定晚于 `user.speech.start` | 实施记录（`swift test` 584/584）；**含一处已知残留窗口**，待真机验证 |
| 15 | [`15_D4_waitingUser下的打断必须停播.md`](./15_D4_waitingUser下的打断必须停播.md) | D4：`.waitingUser` 下的 barge-in 为什么不停残留音频、为什么只该停播不该发 interrupt | 实施记录（`swift test` 587/587）；**真机未验**，另记一批既有 2 秒超时 flaky |

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

> **修订（2026-09-20）**：本表原指向 `MockTTSDecoder.swift` 与 `consumedByTTS` 分支，两者都已随 `e64237e` / `d004869` 删除；回滚注释的行号也从 `:538-557` 移到 `:574-580`。下表按 HEAD `d004869` 核对过。

> **修订（2026-09-20，第二次）**：第二版（下面就收进修订记录的那版）核对的是 `d004869`。本轮接线与删除之后，行号与两行的存在性都变了：`TransportEventRouter` 已接线，`play(frame:)` 与 `AudioPlaybackGate` 已删除。下表按本轮之后的 HEAD 重新核对。

| 组件 | 文件:行 |
|------|---------|
| **`TTSPlaybackCoordinator`**（唯一的播/丢决策点；裸帧入口 `onAudioFrame`） | `Shared/FluentWorkCore/TTS/TTSPlaybackCoordinator.swift:136-143` |
| **`TransportEventRouter`**（传输事件的真实分发点） | `Shared/FluentWorkCore/Architecture/Middleware/TransportEventRouter.swift:63` |
| **生产路由表**（四个 handler 就地定义在这里） | `Shared/FluentWorkCore/Architecture/Middleware/SpeechSessionMiddleware.swift:568`（`makeTransportEventRouter`），组装于 `:880`，分发于 `:958` |
| **控制帧的路由键**（`String` 原始值取线上 discriminator；穷尽 switch） | `Shared/FluentWorkNetworking/Socket/WSControlFrame.swift:174`（`wireType`） |
| 生产 DI：解码 seam（`audioFrameDecoder`）与「引擎即 sink」的绑定 | `Shared/FluentWorkCore/Dependencies/AppDependencies.swift:566-571`、`:74-80` |
| 生产 DI 绑定处的回滚注释（**没有回滚开关**） | `Shared/FluentWorkCore/Dependencies/AppDependencies.swift:571` |
| `WSAudioFrame`（只有 seq、无 turn_id） | `Shared/FluentWorkNetworking/Socket/WSAudioFrameCodec.swift:9` |
| **`LiveAudioEngine.play(pcm:)`**（引擎唯一的播放入口；`playbackRetired` 守卫在此） | `Shared/FluentWorkCore/Services/LiveAudioEngine.swift:697` |
| `RawPCM16FrameDecoder`（`audioFrameDecoder` 的底层实现，一个 codec 两个调用点） | `Shared/FluentWorkCore/Dependencies/AppDependencies.swift:562-564` |
| **传输层的 barge-in 门**（唯一一道；每帧入站二进制都过它） | `Shared/FluentWorkNetworking/Socket/AudioFrameDropGate.swift`（`BargeInAudioGate`） |
| ~~`TTSFrameDispatcher`~~ / ~~`MockTTSDecoder`~~ | 已删除（Stage 4）。文件与 DI 绑定都不在了 |
| ~~`LiveAudioEngine.play(frame:)`~~ / ~~`AudioPlaybackGate`~~ | **已删除**（2026-09-20）。理由与证据见 `07` §2 |
| ~~`EngineBackedTTSDecoder`~~ / ~~`TTSFrameDispatcher`~~ | **已重新删除**（2026-09-20）。`e64237e` 删过、`f3bb127` 加了回来、本轮再次删除 |

## 修订记录

### 2026-09-20：本文档集的前提整体翻转

核对 HEAD `d004869`（iOS）+ 后端 `afe5eb5`。三件事推翻了第一到第四篇的共同前提：

1. **网关开始总是发 `ai.tts.start`**（后端 `3cb3774` 起意、`afe5eb5` 修正顺序：在首帧音频之前、每轮一次）。原「一句话结论」里那条「网关不发 start」的偶然事实消失。
2. **iOS 删掉了 legacy 回退**（`d004869`）。`AudioSink.play(legacy:)` 删除，`onAudioFrame` 无归属即丢（`TTSPlaybackCoordinator.swift:136-143`）。契约 `meta 83_` §2 描述的「停发 start 即自动退回 legacy」不再有对应实现。
3. **Stage 1 的 `TransportEventRouter` 从未接线**，中间件也没有被收敛成路由表：`SpeechSessionMiddleware.swift` 现在是 1470 行（文档原写 1495），仍是巨石。

原文保全如下（被推翻的是判断，不是观察；观察在写下时都成立）：

> iOS 的 AI 语音回放有**两条并行的播放路径**，而 app 之所以还能出声，是因为这两条路径之间恰好踩中了一个「网关不发 `ai.tts.start`」的偶然事实：**设计路径（A）** `ai.tts.start` → `TTSFrameDispatcher` 进入 `.active` → 帧被 `handle(audio:)` 认领 → 交给 `TTSDecoder` 解码播放；**实际路径（B）** 网关不发 `ai.tts.start`，`TTSFrameDispatcher` 永远停在 `.idle`，`handle(audio:)` 返回 `false`，帧「漏」到 `audioEngine.play(frame:)` 直接播。而生产环境 DI 绑定的 `TTSDecoder` 是 `MockTTSDecoder`（只记录、不出声）……这条 2026-09-12 已经踩过一次并回滚（`AppDependencies.swift:538-557`）。

后续各篇的处理方式不同：`01`/`03`/`04` 是当时代的计划与快照，只加注不改写（它们的价值是当时观察到了什么）；`02` 的设计提案按现状逐处修订；`05`/`06`/`07` 的实施记录按代码现状修订并标出被撤回的部分。

### 2026-09-20（当天第二次）：把最后两处尾巴收掉

上一版把「Stage 1 未接线」记为**本系列唯一至今未关闭的缺口**。本轮关掉了它，并删掉了另一处同类的尾巴。

**1. Stage 1 接线了，但形状与原设计不同。** `TransportEventRouter` 成为传输事件的真实分发点；中间件里那个 237 行的 switch 收敛成 `await router.route(event: event)` 一行。**原图里的 `BadgeSink` / `ErrorHandler` / `Telemetry` 三个 owner 从来不存在**，而 `SpeechSessionMachine` 的状态在 Redux store 里、router 接管不了——所以没有把中间件拆成 owner 分离，handler 定义在中间件内部。详见 [`02`](./02_目标架构与组件设计.md) §5。

三处 API 更正是接线的前提，其中一处会直接造成故障：`.failure` 原被硬编码成 `.ignored`，照原样接线会**静默吞掉 socket 断线**。

**2. 引擎侧的水印与其入口删除了。** `AudioPlaybackGate` 不只是没有读者——它的 watermark 唯一赋值点写的是 `lastAcceptedSequence`，而后者只在 `shouldAccept` 内写，`shouldAccept` 的唯一调用点又是永不执行的 `play(frame:)`。**它不可能被武装，即使有帧路由到那里也一个都拦不住。** `play(frame:)` 一并删除；barge-in 的丢弃现在只在传输层发生一次。证据链与 2026-09-12 03:57 的原始记录见 [`07`](./07_Stage4_删除死路径.md) §2。

**3. 顺带重新删掉了两个孤儿文件**：`TTSDecoder.swift`(164) 与 `EngineBackedTTSDecoder.swift`(86)——`e64237e` 删过、`f3bb127` 加了回来、本轮再次删除（删前核对全仓零引用，只剩两处墓碑注释）。

**4. 仍然没有做到的**：中间件没有被拆小——路由只占它 19% 的行数，`audioEventPump` 那个 209 行的 switch 不归 router 管。

> **⚠️ 本轮只跑 `swift test`（565/565），没有做真机验证。** 删除那部分不需要——被删代码不可达是论证过的。**但接线那部分需要**：它改的是活的 dispatch 路径，而这条链路的失败模式历来是「转写正常、没有声音」，两侧单测全绿也照样发生过两次（2026-09-12 静音事故、2026-09-20 的 start 顺序缺陷）。真机验证另开一轮，重点 barge-in 与断线重连。在那一轮通过之前，本轮描述的接线状态应视为**单测已验、真机未验**。
