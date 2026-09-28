# MEMORY.md — fluentwork-ios 项目长期约定

> 权威来源是仓库里的 `AGENTS.md`。这里只记「容易踩、且跨会话会重复用到」的。

## 硬性纪律（`AGENTS.md`）

1. **代码不写注释**（`AGENTS.md` Local Rule 5，2026-09-25 收紧）。不加注释（含文档注释、
   头部块、行内理由）。**也没有别的地方放推理** —— 要留痕就写**提交正文**。
   已存在的注释不动，规则只向前生效。
2. **一次一张票**。不并发实施多个计划中的任务。
3. **跨仓必须串行**：在 `fluentwork-backend` 与 `fluentwork-ios` 之间，先在一侧完成并验证，
   再动另一侧。
4. **开发在 `main` 上，`--ff-only`，不开 PR**。注意远端 `main` 的分支保护要求 PR + 3 项
   状态检查，与这条冲突——每次推送都报 `Bypassed rule violations`，**待仓库管理员处理**。
5. **落地门禁两项**：host Debug build + `swift test`，一起提交。
   **不再要求实现说明文档**（2026-09-25 取消；`docs/` 也已不存在）。
6. **缺陷修复纪律**：每个修复从一条会失败的测试开始，并**破坏实现证明守卫咬得住**。
   证据（逐字的修复前输出）写进**提交正文**，不写文档。
7. **禁用 `NSLock` / `NSRecursiveLock`**。用 actor 隔离或 `OSAllocatedUnfairLock`。

## 本机环境（会反复踩）

1. **`swift build` / `swift test` 一般直接可用**（2026-09-25 实测：`swift build` 80 tasks 4.72s、
   `swift test` 591 tests / 28 suites 6.5s，均未加参数）。**只有当宏插件服务器被沙箱拦住时**
   才加 `--disable-sandbox`，否则会报 `sandbox_apply: Operation not permitted`。
   **不要无条件加这个参数** —— 早先的记录把它写成了「必须」，那是错的。
   ⚠️ **但在 AI agent 的 shell 里是另一回事**（2026-09-29 实测）：那个 shell 外面已经套着一层
   Seatbelt，于是 `swift test` 也要加 `--disable-sandbox`，**`xcodebuild` 还必须再关掉两个内层沙箱**
   —— 见「本机环境」第 5 条。macOS 不支持嵌套沙箱（内核直接拒绝 `sandbox_apply`），
   所以这不是本机故障，也不该记成「构建本来就通不过」。
2. **Bash 工具环境里 `USER` 未设置**（`LOGNAME=root`，但 `whoami` 返回 `tango`）。
   读 `USER` 的 CLI 会挂（已知 XcodeGen 报 `Couldn't find current username` 且静默不生成工程）。
   解法：`USER=$(id -un)` 前缀。
3. **裸 `swiftc` 编译带宏的 SwiftUI 代码必然失败**。要验证 SwiftUI 行为必须走 SPM。
4. **同一文件的多次编辑必须串行。** 同一条消息里对同一文件发多个 Edit，两次都回「成功」，
   但**只有后一次落盘**。不同文件可并发；改完必须 grep 复核，**不要相信「成功」回执**。
5. **落地门禁现在有脚本：`./Scripts/gate.sh`（2026-09-29 建）。** 两腿：腿 1 `swift test`、
   腿 2 `FluentWorkHost` Debug 构建；任一腿红 ⇒ `GATE FAILED` + `exit 1`（**两条腿都跑完再汇总**，
   不是第一步红就停）。**别再手敲那条命令** —— 下面是脚本内部用的形状，仅供排障参考：

   ```bash
   xcodebuild -scheme FluentWorkHost -configuration Debug \
     -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath .derivedData -disableAutomaticPackageResolution \
     -IDEPackageSupportDisableManifestSandbox=1 \
     -IDEPackageSupportDisablePluginExecutionSandbox=1 \
     OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
   ```

   **三个开关都是必需的，缺一即红**（逐个去掉重跑验证过；`project.yml` 里没有
   `OTHER_SWIFT_FLAGS`，所以 `$(inherited)` 是安全前缀）：
   - 缺前两个 ⇒ `Resolve Package Graph` 报 `sandbox-exec: sandbox_apply: Operation not permitted`，
     `exit 74`；
   - 缺 `OTHER_SWIFT_FLAGS` ⇒ `FluentWorkUI` 编译报
     `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found …`
     （`swift-plugin-server produced malformed response`），`exit 65`。
     **根因是宏插件服务器被嵌套沙箱挡住，不是代码问题** —— 别顺着这个报错去改视图代码。
   - 用 `-destination 'generic/platform=iOS Simulator'`，不必指定具体模拟器 id；
     `.derivedData/` 里有热的 `SourcePackages`，**默认 DerivedData 里没有**。
   - 干净 HEAD 上跑同一条命令会得到同样的 `exit 74` ⇒ 判断「红是不是我造成的」时可直接对照。
   - 前两个 flag 的出处是 Xcode/SwiftPM 的构建设置名（见 nono 讨论 #1760 与 Homebrew 讨论 #59
     对同一报错的分析）；这是社区口径，Apple 没有官方文档承诺它长期存在。
   - ⚠️ **`.githooks/pre-commit` 仍是 `exit 0`**（`AGENTS.md` Local Rule 2 是**刻意**的：
     门禁不自己跑）。要不要让钩子调这个脚本是**待拍**，别默认改。
6. **`timeout` 命令在本机不存在**（macOS 没有 GNU coreutils）；要限时用工具自己的 timeout。

## 测试支撑（2026-09-29 收敛，改测试前先读）

- **等待助手只有一份实现**：`Tests/FluentWorkCoreTests/Support/Await.swift` 的
  `waitUntil(timeoutNanoseconds:pollIntervalNanoseconds:label:file:line:condition:)`。
  **不要**再在测试文件里写 `private func waitUntil`。默认预算 **10s**、轮询 10ms。
- **超时会抛 `AwaitTimeout`，消息自带调用点与预算**（`label` / `file` / `line` 三个参数都用
  `#function` / `#fileID` / `#line` 做默认值 ⇒ **调用点不用传**，报错自动指到那一行）。
  ⇒ 新增等待时**不要再写「超时就静默 return」的助手** —— 那会让「实现坏了」表现成「测试通过」。
  收编前有 2 个这样的助手（`waitForBootstrap` ×2、`waitForSpeakingRoomPhase`），已修。
- **`waitForBootstrap` 是共享的**（同文件），`waitForPhase` / `waitForProcessingStage`
  仍是 `SpeechSessionMiddlewareTests` 里的**域内薄包装**（有文档注释、委托给 `waitUntil`）——
  **别为了「数量统一」把它们也删掉**。
- 收敛前的实测数字（写在这里是为了**别再照抄旧清单**）：`waitUntil` **8 份实现 / 158 调用点**，
  等待助手共 **14 个声明 / 10 个文件**，测试错误类型 **15 个定义**（其中 `TimeoutError` **7 份**）。

## 设计令牌（2026-09-29 起）

> **本阶段的票在哪**：`.scratch/issues/2026-09-29-design-phase/README.md` ——
> 它是**设计稿阶段的唯一顺位表**（基建 → 模块 → 局部）。旧的两处
> （`meta/docs/40_.../问题总清单-iOS架构.md`、`.scratch/issues/2026-09-06-W3-ios-tickets/`）
> **没有收口环节、数字已滞后**，本文取代它们的顺位，但**旧清单仍可追溯到细节**。
> ⚠️ 旧清单的错已实测：等待助手「11 份」实为 **14 个声明 / 10 个文件**；
> 错误类型「8 份」实为 **15 个定义**（其中 `TimeoutError` 一个类型 **7 份副本**）；
> 「7 个 `.shared` 单例」**已不成立**（`static let shared` 零命中）；
> 隔离策略「17/5/11」实为 **15/20/14**。**照抄数字前按源码重数。**

- **视觉常量的唯一来源是 `docs/design/DESIGN.md` + `Shared/FluentWorkUI/DesignTokens/DesignTokens.swift`**，
  两者对齐 09-26 稿子快照 `docs/design/2026-09-26-prd-v16-ux/index.html`
  （sha256 `5971251977c787ab0b581d97b3a7befee83686e0a30092b3d2fd2671a4423945`）。
  上游来源是 open-design 项目 `~/.od/projects/09d2063a-de09-40c6-9772-02ab1cda447b/`；
  **重新生成稿子 ⇒ sha 变 ⇒ 令牌必须一起走。**
- **色板是 slate / teal**：底 `#1A2226`、卡片 `#232E33`、品牌 `#4A7C82`（仅装饰）、
  按钮底 `#35646A`、强调 `#7FB3B8`、正文 `#E8EDEF`、次要 `#9AABAF`。
  ⚠️ 2026-08-25 起代码里曾有一套**蓝色板**（`#0B0F14` / `#3D8BFF`），与稿子和 meta `21_` 都对不上；
  2026-09-29 已换成 teal。**不要再引入 `#3D8BFF` 那一族。**
- **没有 danger / red**：设计原则「降低开口焦虑」刻意避开纯红 —— 语言学习里的「错误」是中性事件。
  失败与待改进用 `training #C9A45C` / `improve #C97B5C`。
- 守卫在 `Tests/FluentWorkCoreTests/UI/DesignTokensTests.swift`：手写的「稿子变量 → Swift 路径 →
  期望值」对照表 + 用 WCAG 2.1 公式**重算**对比度（不是抄稿子的数字）+ 一条仓级守卫
  「`#RRGGBB` 字面量只许出现在 `DesignTokens.swift`」。`Color(hex:)` 是 **fileprivate**，
  别的文件连构造都构造不出来。
- **视图尚未迁移**：10 个视图仍走系统语义色（`.secondary` ×32、`.red` ×5 …）。
  按每屏各自的 ticket 走，**不做全量覆盖** —— 每屏还有自己的状态矩阵（稿子 §06/§07）要对。

## 闪测（Drill）—— 契约逼出来的规则，改前先读

代码分布：DTO + 协议 + 客户端在 `Shared/FluentWorkNetworking/API/DrillModels.swift`；
领域与纯状态机在 `Shared/FluentWorkCore/Drill/`（`DrillPrompt` / `DrillRoundState` / `DrillRoundMachine`）。
契约是 `fluentwork-backend/api/openapi-v1.yaml` 的 `/drill/round|judge|appeal`。

1. **「无英文提示」靠类型，不靠 UI 纪律。** 契约的 `DrillCard` 会把 `expression_en` 一起发下来，
   而 PRD E1 要求无提示 ⇒ 作答期只用 `DrillPrompt`（仅 `block_id` + `intent_zh`）。
   别把 `DrillCard` 传进作答态。
2. **`judged == false` 不是失败。** 契约原话：a judge that did not run is not evidence that the
   learner was wrong ⇒ 不记失败、不重排、**不可申诉**，只能原样重发（`retryable`）。
   「待确认」由它驱动 —— **客户端不该有 3 秒计时器**（判官超时是服务端 1.5s，服务端一定会回）。
3. **`canAppeal = judged && recorded && record_id != 0`**。`record_id` 为 0 = 账本写失败，
   申诉没有可指向的对象。三个条件缺一都不能给按钮。
4. **重发必须逐字复现**：`response_ms` 保持原值，不按重发时刻重算（它与原记录对齐）。
5. **`restored: true` ⇒ 本地回退**：本轮通过数、`automatedDelta`、待复习集合、
   **以及本轮尾部的重排副本**都要撤。`already_appealed: true` ⇒ **什么都不改**（幂等）。
6. **超时与「这题卡住了」走同一条路**：都提交一次**空作答**（`asr_text: ""`），
   否则后端 SM-2 调度不推进、这张卡下一轮仍是原状态。⚠️ 后端是否接受空 `asr_text` **待确认**。
7. **`next_due_at` 用 `SessionHistoryJSON.makeDecoder()`**（它处理 Go `time.Time` 的
   RFC3339Nano **变长小数位**；裸 `JSONDecoder()` 与 `.iso8601` 都会在真实数据上失败）。
   类型名偏窄是已知债 —— 想改名就顺手把它提成中性名，别复制一份。
8. ⚠️ **待拍**：「第 N / M 题」的 M 与失败卡重排的关系（机器把 `planned` 与 `position`
   两个数都暴露，**没有替产品定显示口径**）。

## 语音链路的关键事实（改这块之前先读）

- `SpeechSessionMachine` 是纯状态机，零 IO。**没有 phase→`.idle` 的迁移**——`.enterRoom`
   重置 `state.session = .initial`，是回 `.idle` 的唯一路径。
- `SpeechSessionMiddleware` 里有两个泵：`audioEventPump`（上行）与 `transportEventPump`（下行）。
   两个都由 `OnceFlag` 保证**每进程只起一次**，**且都属于引擎/传输层，不属于会话**——
   `endSession` 刻意不取消它们。**任何 `return nil` 出泵循环都是缺陷**（已撞到 D14、D15 两次）。
- `SpeechCaptureGate` 是「这一段 PCM 该不该上行」的唯一权威。关闭入口只有 `endSpeech()`
  与 `abort()`。`takeForwardDecision()` 在拒绝时**计数**，所以关闸本身就是抑制器。
- 二进制音频帧：`[4B 大端 sequence] + payload`，**没有 `turn_id`**（这就是 D7 与 Stage 3）。
- 埋点是**字符串字面量**，不是符号——改名或删键编译通过、测试全绿，而真机日志里那行没了。
  `70_/24_` 已为上行 11 条建断言。

## 复盘习惯

- 修完一处缺陷，**grep 同形状的兄弟**（D14 修完，同文件里还有 3 处逐字同形）。
- **数完数字，再问「命中的是不是都算数，没命中的是不是都不算数」**——两头都要问。
  本仓已三次同错：注释被多算、多行调用被少算、按前缀扫一族漏掉不共享前缀的成员。
