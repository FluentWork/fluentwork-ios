# 设计稿阶段 · 规划（2026-09-29）

> **顺序（Tango 定的）：基建 → 模块 → 局部。基建不清完，不开模块。**
>
> 本文取代之前散在 `fluentwork-meta/docs/40_研发流程与协作/问题总清单-iOS架构.md` 与
> `.scratch/issues/2026-09-06-W3-ios-tickets/` 里的顺位 —— 那两份**没有收口环节**，
> 数字与状态已经滞后（本文逐条重数过，见 §2）。

**阶段定义**：2026-09-26 拿到了 PRD V1.6 的 14 屏高保真稿
（`docs/design/2026-09-26-prd-v16-ux/index.html`），`docs/design/DESIGN.md` 已把令牌落进代码。
⇒ 这一阶段做的是**「把稿子变成能跑的屏」**，而稿子本身不是产物。

## 0. 进度

| 票 | 状态 | 落点 / 证据 |
|---|---|---|
| `F1` 门禁脚本 | ✅ **已完成** | `Scripts/gate.sh`；`GATE PASSED`（腿 1 / 腿 2 全绿），失败路径实测会红（腿 2 用一个不存在的 scheme ⇒ `GATE FAILED` + `exit 1`） |
| `F2` 测试支撑收敛 | ✅ **已完成** | `Tests/FluentWorkCoreTests/Support/Await.swift`；`waitUntil` **8 → 1 份**、错误类型 **16 → 1 份**（只余 `AwaitTimeout`）、`waitForBootstrap` **2 → 1 份且不再静默成功**、`waitForSpeakingRoomPhase` 内联。**664 tests / 30 suites 全绿**；变异（超时错误丢掉调用点与预算）⇒ 3 条断言红 |
| `F3` REST 契约守卫（**端点面**） | ✅ **已完成** | 契约镜像进仓（`Resources/Schemas/openapi-v1.yaml`，由 `Scripts/sync-shared-schemas.sh` 从 backend 同步）+ `Tests/.../Networking/OpenAPIContractTests.swift` 三条判据（代码↔对照表↔契约 三方一致 + 对照表覆盖源码每个 case）。变异 4 条全咬 |
| `F3-b` REST 契约守卫（**字段面**） | ✅ **已完成** | `Tests/.../Networking/OpenAPIFieldContractTests.swift`：20 个模型的手写映射（含两处**名字不一致**：`DrillVerdict`→`DrillJudgeResponse`、`DrillAppealOutcome`→`DrillAppealResponse`，以及一处**内联响应**：`DeleteCorpusBlockResponse`→`DELETE /corpus/blocks/{id}`）+ 三条判据。变异 3 条全咬，另外**首次运行就咬掉两条说谎的豁免条目** |
| `F4`–`F9` | ⏳ 未开始 | 顺位：F4（DI 收紧）… |


---

## 1. 表 A —— 基建（先做完这些）

证据等级：【实测】= 本轮跑过命令 /【读码】= 读过源码 /【推断】/【未核】。

| 票 | 目标 | 证据 | 交付 | 验收 | 依赖 |
|---|---|---|---|---|---|
| **F1** | **把两腿门禁变成脚本** | `Scripts/` 里没有任何 gate 脚本；`.githooks/pre-commit` 是 `exit 0`；`AGENTS.md` Local Rule 1 只写了「`swift test` + host Debug 构建」【实测】 | `Scripts/gate.sh`：腿 1 `swift test`、腿 2 host Debug 构建（**必须带三个反嵌套沙箱开关**，见 `MEMORY.md`） | 脚本 `exit 0`；**在干净 HEAD 上也 `exit 0`**；变异：删掉腿 2 的一个 flag ⇒ 脚本红 | — |
| **F2** | **测试支撑收敛**：14 个等待助手 + 15 个错误类型 → 一份 | **14 个声明 / 10 个文件**：`waitUntil`×8、`waitForPhase`×2、`waitForBootstrap`×2、`waitForSpeakingRoomPhase`×1、`waitForProcessingStage`×1。错误类型 **15 个定义**，其中 **`TimeoutError` 一个类型就有 7 份副本**【实测】 | `Tests/…/Support/Await.swift`（**超时时必须报出「路过但没等到」的帧清单**）+ 一个 `TestTimeoutError`；逐文件替换 | 副本数 14→1、15→少数；全量测试绿；变异：让助手在超时时**丢弃**路过数据 ⇒ 必须有判据红 | F1 |
| **F3** ✅ | **REST 契约守卫（端点面）** | `find . -name 'openapi*'` **零命中** —— REST 契约**根本没进 iOS 仓**；而 `FluentWorkAPI.swift:4` 自称 "aligned to `fluentwork-backend/api/openapi-v1.yaml`"，**没有任何东西校验**【实测】。WSS 侧有镜像 + 守卫，REST 侧是空的 | 镜像契约进仓（`Scripts/sync-shared-schemas.sh` 扩一个 backend 源）+ 守卫断言：每个 `FluentWorkAPI` case 的 path/method 在契约里存在（**另加**：代码的 path/method 要与对照表一致、对照表要覆盖源码里的每个 case） | **修前必红**：把 `.drillRound` 的 path 改成 `/drill/rounds` ⇒ 红。⚠️ **本轮的 drill 键是我手工核过的**，正因为没有这条守卫 | F1 |
| **F3-b** ✅ | REST 契约守卫（**字段面**） | 同上；字段面是「客户端读的键，契约必须声明」 | 20 个模型的手写映射 + `clientKeys ⊆ contractKeys` + 三条反空洞下限（每类型有键、总键数 ≥ 80、扫到 ≥14 个解码类型）+ **豁免名单的过期检测** | 修前必红：把契约的 `promoted` 改名 ⇒ 点名 `DrillVerdict` 读 `promoted` | F3 |
| **F4** | **DI 收紧**：去掉可选注入的默认值 | `?? Container.shared` **10 处**，`Container.shared` 共 17 处【实测】；清单原文「10 处」这条**数字是对的** | 去掉默认值让 container 必传（或引入显式 `AppContainer`） | 全量测试绿；构造点不再有「忘了传就静默拿单例」的路径 | F1 |
| **F5** | **并发隔离口径**（先量再定） | actor **15** / `@MainActor` **20** / `OSAllocatedUnfairLock` **14**【实测】。⚠️ 清单原文写「17 actor / 5 `@MainActor` / 11 锁」——**三个数全变了**（代码在演进）。「三种策略并存、无统一规则」是【推断】 | 一份「谁该用哪种」的口径（IO 边界 → actor；UI 状态 → `@MainActor`；窄临界区 → `OSAllocatedUnfairLock`），**只对新代码生效**，不做全仓迁移 | 口径写进 `AGENTS.md`；新代码不再出现第四种 | — |
| **F6** | **`AVAudioSession` 所有权**（高风险路径） | 两个实现点，`DailyReadAudioPlayer` 曾绕过 owner（局部已修）；**结构问题仍开着**；现有 `isActive` 是**永不取假的判据**【读码】 | 单一 owner 类型 + 可查询的「谁在占用」真值 | 真机验证（与 iOS-S0-3 合并做） | — |
| **F7** | **设计资产落地** | 稿子 §2.5 的 **24 个线性图标（1.5pt 描边）未交付**，现在用 SF Symbols 顶替，描边与圆角都不一致；**动态字体未接**（130% 不破版未验证）【实测 `DESIGN.md` §7/§8】 | 图标集 + `DesignTokens.Icon` 映射；已迁移的屏接 `@ScaledMetric` | 图标描边/圆角与稿子一致；动态字体 130% 截图不破版 | — |
| **F8** | **CI 结构断言改成真的** | `ios-ci.yml` 断言 `App / Modules / Services / Resources / Tests`，而仓里只有 `App / Shared / Tests / Scripts` ⇒ **每次推送必失败**【实测】 | 改成断言真实骨架；并让 CI 至少跑 `swift test` | CI 在 main 上不再结构性失败 | — |
| **F9** | **离线缓存补齐** | `Storage/` 只有语料库三件套（`CorpusCacheStore` / `CorpusOutboxStore` / `CorpusSyncMetadataStore`）+ `SecureStorage`。稿子 §07 场景 06 要求「语料库 **/ 历史 / 每日一读** 走本地缓存」⇒ **只做了 1/3**【实测】 | 历史与每日一读的缓存层（沿用语料库的既有形状，不新立一套） | 断网进历史/每日一读不留白页；有判据 | F1 |

**治理项（不是我在仓内能修的，挂账）**：远端 `main` 的分支保护要求 PR + 3 项状态检查，与
`AGENTS.md`「在 `main` 上开发、不开 PR」冲突（= iOS-S0-5）⇒ **需要仓库管理员**。

---

## 2. 表 B —— 残留票清账（逐条重数，不信旧清单）

### 2.1 旧清单的**数字错了**（四类错法，与 backend 侧同病）

| 条目 | 旧清单写的 | 本轮实测 | 错在哪 |
|---|---|---|---|
| `iOS-S1-2` 等待助手 | 「11 份（`waitUntil`×8 + `waitForPhase`×2 + `waitForProcessingStage`×1）」 | **14 个声明 / 10 个文件** | **只数了显眼的三族**，漏掉 `waitForBootstrap`×2 与 `waitForSpeakingRoomPhase`×1（11+3=14） |
| `iOS-S1-2` 错误类型 | 「8 份错误类型，已漂移 5 类」 | **15 个定义**，其中 `TimeoutError` **一个类型 7 份副本** | 数量错，**成因也错**：真正的问题是同一个类型的复制，不是「漂移了 5 类」 |
| `iOS-S2-6` | 「7 个 `.shared` 进程单例」 | `static let shared` **零命中** | 该形态**已不存在**（要么已解决、要么当时口径不同）⇒ **要重新定义口径**，不能照抄 |
| `iOS-S2-5` 隔离策略 | 「17 actor / 5 `@MainActor` / 11 锁」 | **15 / 20 / 14** | 三个数全变（代码在演进）⇒ 判断或许仍成立，**数字必须重数** |

### 2.2 状态已变的（清单没跟上代码）

| 票 | 清单写的 | 实际 |
|---|---|---|
| `iOS-S0-1`（Stage 3 轮次归属） | 「已决：排期，作为下一项主任务」 | ✅ **已收口并推送**：infra `f1a06e8`+`1a54ee4` → iOS `ab5f44e` → backend `662c732`。剩下的只有**一次真机跑**（= T6） |
| `iOS-S1-1` | （原为「加测试」） | ✅ 已关闭 —— 前提被推翻（零读点，是死代码），已删除 |
| `iOS-S1-9` | 「8 个采集诊断的 mark 名没有测试钉住」 | ✅ 已关闭，**数量更正为 11** 并全部钉住 |
| `iOS-S2-8`（`Modules/` 空目录） | 仍开着 | ✅ 已解决（`80c8209` 删空壳） |
| `iOS-S2-9` | 仍开着 | ✅ 已关闭（`deinit` 不再无条件碰输入节点；单测打开输入设备 28→0 次） |
| `iOS-S1-10` | 仍开着 | ⚠️ **局部已修、结构仍开** ⇒ 收进 **F6** |

### 2.3 I14–I21 这批「待建」票 —— **5/8 其实已经落地了**

| 票 | 声称 | 实测 | 证据 |
|---|---|---|---|
| `I14` 创建练习弹层 | 待建 | ❌ **没做**（屏 11 无任何视图） | 【实测】`Shared/` 无 materials 调用 |
| `I15` 说的房间 TTS 播放 | 待建 | ✅ 已落地 | 【实测】`TTS/AudioFrameDecoder.swift`、`TTSPlaybackCoordinator.swift`、`WSAudioFrameDecoderAdapter.swift` |
| `I16` 完整转录浮层 | 待建 | 🟡 **部分**：有 `liveTranscript` + `transcriptView`（纯文本），**没有**稿子 §4.2 的半透明浮层 + 波形/状态条形态 | 【实测】`SpeakingRoomView.swift:650` |
| `I17` 闪测 UI | 待建 | ❌ **没做**（`HostRootView.swift` 的 `flashRoot` 是 `Text("闪测（占位）")`） | 【实测】 |
| `I18` 话题卡 UI | 待建 | ❌ **没做** | 【实测】`Shared/` 里 `TopicCard` 只在 `FeaturePluginRegistry` 命中一处字符串 |
| `I19` 历史回顾列表 | 待建 | ✅ 已落地 | 【实测】`SessionHistoryRootView.swift` + `SessionDetailView.swift` |
| `I20` Prompt 工程师接入 | 待建 | ✅ 已落地 | 【实测】`Prompt/SystemPromptBuilder.swift`、`RecordedHit.swift`、`UserLevel.swift` |
| `I21` 状态机子状态扩展 | 待建 | ✅ 已落地 | 【实测】`SpeechSessionState.processingStage` + `ProcessingTimeouts.swift` |

⇒ **`I14` / `I17` / `I18` 三张没做的，恰好就是稿子里「完全没有视图」的那三屏。**
这不是巧合：它们是这一阶段的主体。

### 2.4 PRD 工单的残留

| 票 | 状态 | 备注 |
|---|---|---|
| `T1/T2/T3/T4/T5-a` | ✅ 已完成 | 见 `meta/docs/40_.../PRD核心业务逻辑落地工单.md` |
| **`T5-c`**（粘贴框 2000 字） | ❌ 仍开 | **前置「UI 未设计」现在解除了** —— 稿子屏 11 就是它 |
| **`T1-c`**（客户端把 `material_id` 传上来） | ❌ 仍开 | D2 已拍（属业务逻辑）；两处 `createSession(materialID: nil)` 仍是硬编码 |
| **`T5-b`**（提炼产物） | ⏸ 等 D1 | 若 T1 选了 a（注入正文），这张可以不做 |
| **`T6`**（h8 真机端到端） | ❌ 仍开 | 需要设备窗口；与 iOS-S0-3、F6 的真机验证**可以合并一次**
| **`T7`**（性能红线基线） | ❌ 仍开 | 不阻塞开发 |
| `iOS-S0-2`（D5 选项 2） | ❌ **已决未落地** | `ai.tts.start` 的 `voice_id`/`sample_rate`/`codec` 仍是必需 `decode`；原设计理由所在的文档已随 `docs/` 删除 ⇒ **动手前要重新推导形状** |
| `iOS-S0-3`（真机验 barge-in / 重连） | ❌ 仍开 | 需设备 |
| `iOS-S1-3/S1-4/S1-5/S1-7/S1-8` | ❌ 仍开 | 其中 **S1-5（端到端测试只有 51 行）** 已收进表 A 的思路（F2/F3 之外单列） |

---

## 3. 表 C —— 新阶段票（有设计稿）

依赖图：**基建（表 A）→ 批次 1 → 批次 2 → 批次 3**；批次 3 内各屏相互独立，可并行。

### 批次 1 —— 解锁「后端已完成却闲置」的那条线（PRD T5-c / T1-c / T4 客户端半张）

| 票 | 目标 | 依赖 | 依据 |
|---|---|---|---|
| **D1** | 素材数据层：materials 客户端（`POST /materials` + `GET /materials/{id}`） | F3 | 契约已冻结；T1/T4 的服务端都完成了 |
| **D2** | `createSession` 带上 `material_id`（两处硬编码 `nil`） | D1 | T1-c；D2 决策已拍 |
| **D3** | **创建练习弹层**（屏 11 = `I14` = `T5-c`）：粘贴框实时字数 + 2000 字截断 + 「将基于前 2000 字生成」+ 场景 + **时长二选一** + 提炼 loading | D1、D2、F7 | 稿子屏 11；`docs/design/ui-adjustments.md` §4 |
| **D4** | 迷你会话落客户端（`turn_limit` / `session_complete`；客户端**真零命中**） | D2 | T4 的服务端半张已完成 |
| **D5** | 工作台入口卡标注预期时长 + 「继续上次」 | D4 | 稿子屏 01；PRD §4.1 |

### 批次 2 —— 闪测（核心逻辑已就绪，只差接线与 UI）

| 票 | 目标 | 依赖 | 依据 |
|---|---|---|---|
| **E1** | 把 `DrillRoundMachine` 接进 Redux：`AppState` + `DrillFeature` + middleware（含 token 解析、定时器、录音） | F1 | 逻辑层已落地并有 18 条测试 |
| **E2** | 闪测三屏 UI（屏 05/06/07 = `I17`） | E1、F7 | **按 `docs/design/ui-adjustments.md` §1–§3 的调整点做**（待确认由 `judged:false` 驱动、申诉三态、结算要能回退） |
| **E3** | 闪测空态（§07 场景 05：语料库为空时不给空跑） | E1 | 稿子 §07 |

### 批次 3 —— 其余屏对齐（各屏独立，可并行）

| 票 | 屏 | 依据 |
|---|---|---|
| **F-01** | 屏 01 工作台（数据条 + 今日三件事 + 每日一读卡 + 话题建议卡） | 稿子 §04 |
| **F-02** | 屏 02/03 说的房间（语音状态机视觉 + 徽章 + 目标胶囊 + 救援气泡三点指示器 + 转录浮层形态 = `I16` 剩余） | 稿子 §4.2 / §06 |
| **F-03** | 屏 04/14 回顾页（Top 3 展示纪律 + 段落层 + 注册时机面板） | 稿子 §4.3；注册要等 G1 决策 |
| **F-04** | 屏 08 语料库进步证据（`real_use_count` + 状态灯形态 ○/◐/●） | 稿子 §4.5 |
| **F-05** | 屏 09 每日一读（跟读自评 + 语速 0.8/1.0/1.2） | 稿子 §4.6 |
| **F-06** | 屏 10 话题建议页 = `I18`（前置：语料 ≥20） | 稿子 §4.7 |
| **F-07** | 屏 12 设置（AI 语速进第一组） | 稿子 §4.8（V1.6 变化点） |

**后置（明确不做）**：屏 13 订阅页（`21_` §4.8：MVP 期入口隐藏，服务端开关）、浅色主题、
发音评测（模块 I 整体 V1.1）、`T5-b`（等 D1 决策）。

---

## 4. 开工前必须拍的（三条，全部有前置性）

1. **「第 N / M 题」的 M 与失败卡重排的关系** —— 稿子同时要求「10 题」与「失败卡插入本轮尾部」
   而重排会推过 10。机器把 `planned` 与 `position` 都暴露了，**显示口径没有替你定**。
2. **限时 5 秒到点，后端收不收空 `asr_text`** —— 客户端按「提交一次空作答」实现
   （`response_ms: 5000`），否则 SM-2 调度不推进、这张卡下一轮仍是原状态。**需要后端确认。**
3. **`T5-b` / D1 决策**（提炼产物注入正文还是产物）—— 决定 D1 是天级还是小时级。

## 5. 第一条做什么

**F1（门禁脚本）。** 它保护后面每一张票；没有它，每一票都要人肉拼那条带三个沙箱开关的命令，
而那条命令今天是靠一次完整的排查才找回来的。
