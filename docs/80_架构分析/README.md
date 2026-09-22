# fluentwork-ios 架构分析（系列）

**日期**：2026-09-22
**分析基线**：`2aa8795`（本地 main，含本轮 `12_`–`21_` 十张票）
**范围**：`Shared/` 七个 SPM target + `App/` + `Tests/`，共 19581 行生产代码、16252 行测试代码
**不包含**：产品/交互设计；服务端（另见 `fluentwork-backend/docs/104_架构分析/`）

---

## 这份系列是什么

一份**读代码得出的**架构分析。它回答三个问题：哪些是好的、哪些是坏的、哪里有真问题。

它与 `docs/70_tts_wss_refactor/` 的分工：

| | `70_tts_wss_refactor/` | `80_架构分析/` |
|---|---|---|
| 对象 | TTS/WSS **一条链路** | **整个 iOS 仓** |
| 形式 | 逐张票的实施记录（含红输出） | 按架构轴分章的分析 |
| 时间性 | 快照式，带修订记录 | 快照式，带日期与基线提交 |

`70_` 里已经定案的结论这里**不重复**，只引用。

## 方法

1. **先读代码，再下判断。** 每一条结论后面跟 `文件:行`，可当场复核。
2. **标确定性。** 分三档：
   - **【实测】** —— 有命令输出或测试输出
   - **【读码】** —— 从源码直接读出，未运行
   - **【推断】** —— 从读到的推出来，可能有别的解释
3. **拆开再判。** 同一个现象常捆着几件成立程度不同的事，逐条给结论。
4. **不评价风格。** 「我不喜欢」不是发现；「这会让 X 发生而没有人会知道」是。

## 结论摘要

### 好的

| # | 结论 | 证据 | 确定性 |
|---|---|---|---|
| G1 | **依赖方向干净，无循环。** Networking 不知道 Core；Core 不知道 UI；UI 不直接碰 Networking | `docs/80_架构分析/01` §2 | 【实测】 |
| G2 | **状态机是纯函数。** 无 `async`、无 IO、无时钟；非法转换显式回滚并返回 `[]` | `SpeechSessionMachine.swift:8-12`、`:342-346` | 【实测】 |
| G3 | **状态只能经 reducer 改。** `Store.state` 是 `private(set)`，全仓 0 处外部赋值 | `Store.swift:8`；grep 0 命中 | 【实测】 |
| G4 | **测试量接近生产量**（16252 / 19581 行），587 条 `@Test`、1588 条 `#expect` | `docs/80_架构分析/04` §1 | 【实测】 |
| G5 | **路由表是静态可断言的，且用生产工厂驱动** | `TransportRoutingEquivalenceTests.swift:69-98` | 【读码】 |
| G6 | **取舍都写下来了**，包括被推翻的判断（带日期与提交号） | `07_` §2 的修订块、`10_` 的 D1/D3 追溯标注 | 【读码】 |
| G7 | **未知帧宽容与后端对称。** 两侧都选择「忽略 + 计数」而不是「回错误」，且都写了理由 | `URLSessionSocketTransport.swift:316-332` vs 后端 `handler_control.go:465-486` | 【读码】 |

### 不好的

| # | 结论 | 证据 | 确定性 |
|---|---|---|---|
| B1 | **两个巨石**：`SpeechSessionMiddleware` 1725 行、`LiveAudioEngine` 1621 行 | `wc -l` | 【实测】 |
| B2 | **Moya 钉在个人 fork 的 `master` 分支**，不是 tag/revision | `Package.swift:27` | 【实测】 |
| B3 | **DI 是「可注入」而非「必须注入」**：11 处 `container ?? Container.shared`，7 个 `.shared` 进程单例 | `AppDependencies.swift:652/685/695/705/714/724/739` | 【实测】 |
| B4 | **`Modules/` 是空目录**（只有 `.gitkeep`） | `find Modules -mindepth 1` | 【实测】 |
| B5 | **同名测试替身跨文件重复**：`StubCorpusClient` ×3、`StubDailyReadAPIClient` ×3 | `04` §5 | 【实测】 |
| B6 | **`App/` 的 `HostRootView` 886 行**，是全仓第三大文件，且在最小的 target 里 | `wc -l` | 【实测】 |

### 有问题的

| # | 问题 | 影响 | 证据 |
|---|---|---|---|
| P1 | **归属仍是控制帧时序推断**（D7） | 网关违约时旧轮迟到帧会被播出去 | `TTSPlaybackCoordinator.swift:136-143` |
| P2 | **音频路径每帧两次 actor 跳转**（D8），而路由器文档明确反对其中一次 | 250 帧/轮 → 500 次跳转，压在延迟最敏感的路上 | `TransportEventRouter.swift:18-24` vs `TTSPlaybackCoordinator.swift:46` |
| P3 | **`audioEventPump`（上行）未纳入路由**（D9），209 行第二个大 switch | 两张路由表、两种风格 | `SpeechSessionMiddleware.swift:436-680` |
| P4 | **真机从未验证** barge-in 与断线重连 | 单测全绿而两侧都发生过真机静音事故 | `70_/08_` §3 |
| P5 | **超时值的理由只有一份副本**：`SpeechSessionMiddlewareTests.swift:2155-2168` 写清了为什么从 1s 提到 10s，而 `SpeakingRoomSessionWiringTests` 还有 **65 处** 1s；另有一批 2 秒超时的 flaky | 门禁噪声；同一节课只学了一次 | `04` §3.2、`70_/15_` §7 |
| P6 | **`LiveAudioEngine` 有一处无条件 `removeTap`**（`deinit`） | 已在 `70_/16_` §7.1 记录，未修 | 同左 |

## 章节

| # | 文档 | 回答什么 |
|---|---|---|
| 01 | [模块划分与依赖方向](./01_模块划分与依赖方向.md) | 七个 target 的边界成立吗？依赖方向有没有被破坏？ |
| 02 | [状态管理与依赖注入](./02_状态管理与依赖注入.md) | Redux 的纪律守住了吗？DI 的默认值是什么？ |
| 03 | [语音链路的所有权](./03_语音链路的所有权.md) | 谁决定播/丢、谁决定打断？为什么这轮收敛过？ |
| 04 | [测试架构](./04_测试架构.md) | 587 条测试测的是什么高度？替身体系覆盖了什么、漏了什么？ |
| 05 | [问题清单与建议](./05_问题清单与建议.md) | 按严重度排序，每条给动作与是否需要产品/后端决策 |

## 阅读前提

默认读者已了解：TGReduxKit（State/Action/Reducer/Middleware→Effect/Store）、FactoryKit（Container/register/cached/shared）、Swift 6 并发（actor / `@MainActor` / `Sendable` / `OSAllocatedUnfairLock`）。

若不熟悉本仓的 TTS/WSS 链路，先读 [`docs/70_tts_wss_refactor/README.md`](../70_tts_wss_refactor/README.md)。

---

## 定稿前的自校（2026-09-22）

写 `05` 时对全系列做了一遍复核，**发现并改正了三处自己的错误**。记在这里，因为「本系列的数字可当场复核」是它唯一的价值来源。

| 原写法 | 实际 | 教训 |
|---|---|---|
| `04` §3.1：`waitUntil` 有 **4 类**漂移 | **5 类**——漏了「`timeoutNanoseconds` 是否给默认值」（7 份必传，`SpeechSessionMiddlewareTests.swift:2170` 默认 10s） | 只比对了参数表的前几项就下了结论 |
| `04` §3.2：用默认超时的调用点 **14** 处 | **25** 处（全部在 `SpeechSessionMiddlewareTests`） | **用 `grep` 数多行调用**：`waitUntil(` 与 `timeoutNanoseconds:` 分写两行时会被漏掉。改用脚本解析后数字才对 |
| `02` §4.4/§4.5：`OSAllocatedUnfairLock` **13** 处 | **11** 处实例（`grep` 的 14 个命中里 3 个是注释） | 数了文本命中，没数实例——而紧挨着的枚举本来只列了 11 个行号 |

顺带澄清一条容易被误读的：`grep NSLock` 在生产代码里有 4 个命中，**全部是注释**（解释「`OSAllocatedUnfairLock` 取代了 `NSLock`」）。生产 `NSLock` 实例数确实是 **0**。

**这三处都不影响 `05` 的结论**（S1-2/S1-3 的判据反而更强了：漂移从 4 类变 5 类，受影响的调用点从 14 处变 25 处），但如果不改，它们会成为本系列第一批「写着 `文件:行` 却对不上」的条目——也就是 `70_/20_` §7 记的那个形状。

