# UI 待调整清单（闪测 · 创建练习弹层）

> **当前顺序：核心业务逻辑 → 面向协议 → UI（最后）。** 本文只登记「UI 阶段要改什么」，
> 以及**已经被契约逼出来的硬事实** —— 后者虽属逻辑层，却会直接改掉稿子上这两屏的形态。

来源：`2026-09-26-prd-v16-ux/index.html`（屏 05/06/07、屏 11）
× PRD §7.5 模块 E、§六 Tab 2、§5.3，`21_` §4.4
× `fluentwork-backend/api/openapi-v1.yaml`（`/drill/round|judge|appeal`、`/materials`）。

---

## 一、屏 05 · 闪测答题（需要调整）

### 1.1 已被契约逼出来的（逻辑层已落地，UI 必须跟着改）

| # | 稿子写的 | 契约/PRD 的硬事实 | UI 要改成 |
|---|---|---|---|
| 1 | 屏 05 只显示中文意图（对） | `GET /drill/round` 的 `DrillCard` **会把 `expression_en` 一起发下来** | 「无英文提示」不能靠 UI 纪律 —— 客户端已用 `DrillPrompt`（只有 `block_id` + `intent_zh`）进入作答态，**答案在类型层就不在手上** |
| 2 | 「超过 3 秒未返回 ⇒ 待确认」 | 判官超时是 **1.5s**，且服务端**一定会回**：`judged: false` + `retryable: true` | **删掉客户端那个 3 秒计时器**；「待确认」由 `judged == false` 驱动 |
| 3 | 待确认落在失败族的语感里 | 「a judge that did not run is **not evidence** that the learner was wrong」 | 待确认**不算失败、不重排**；给「重试」而不是「下一题」 |
| 4 | — | `retryable` 是「**把这次尝试原样再发一次**」 | 重发时 `response_ms` 必须保持原值，**不能按重发时刻重算**（已落判据） |
| 5 | 「这题卡住了」＝ 记失败并插本轮尾部（对） | 与超时同路：都要把一次尝试送到后端，否则 SM-2 调度不推进、这张卡下一轮仍是原状态 | 超时/跳过都提交**空作答**（见 1.2 第 2 条） |

### 1.2 需要你拍的两条（我不替产品决定）

1. **「第 N / M 题」的 M 与重排的关系。** 稿子同时要求「10 题」和「失败卡插入本轮尾部」，
   而重排会把实际作答次数推到 10 以上。机器现在把两个数都暴露出来
   （`planned` = 拉到的题数、`position` = 当前第几次作答），**显示口径留给 UI 阶段定**。
2. **限时 5 秒到点，后端收不收空 `asr_text`。** 契约里 `asr_text` 是 `required` 但没有 `minLength`，
   所以客户端按「提交一次空作答」实现（`asr_text: ""`、`response_ms: 5000`）——
   不提交的话这张卡不会被重新排期。**需要后端确认这个口径**。

---

## 二、屏 06 · 判定与申诉（需要调整）

| # | 稿子写的 | 契约的硬事实 | UI 要改成 |
|---|---|---|---|
| 1 | 无条件给「我说的是对的」 | `record_id` **为 0 时代表账本写失败**，申诉没有可指向的对象 | 申诉区三态：**可申诉 / 不可申诉（说明原因）/ 已申诉**；`canAppeal = judged && recorded && record_id != 0` |
| 2 | 无「已申诉」形态 | `already_appealed: true` ⇒ 第二次申诉**什么都不改** | 申诉成功后按钮变「已申诉」，不再可点（已落判据） |
| 3 | 「申诉会回流标定 ASR」（对） | `restored: true` ⇒ 这次尝试覆盖掉的调度被**放回** | 申诉成功后，屏 07 的「已自动化 +N」与本轮通过数要**回退**，该卡从待复习里移除，且**本轮尾部的重排副本要撤掉**（已落判据） |

---

## 三、屏 07 · 结算（需要调整）

- 「已自动化 +1」在稿子里是**单向**的。申诉成功会把它回退 ⇒ 需要支持回退的呈现（或至少不撒谎）。
- 「2 张待复习」的集合语义：机器按「最终仍未答对」维护（重排后答对即移出）。
- 「稍后还会再来一次 —— 它们会在你快忘记的时候出现」与屏 05 的「插入本轮尾部」是**两件不同的事**：
  本轮尾部是客户端的重排，间隔重复是服务端的调度。文案把两者混在一起，**要拆**。

---

## 四、屏 11 · 创建练习弹层（需要调整）

**你已提出这一屏需要调整；具体改动点以你的描述为准。** 以下是与实现顺序相关、且已被契约定死的部分：

| # | 事实 | 对弹层的影响 |
|---|---|---|
| 1 | `POST /materials` 是 **202 queued**，要 `GET /materials/{id}` 轮询 `refine_status` | 提交后**不能直接进房间**：需要一个「正在提取讨论点…」的**有预期 loading**（稿子 §07 明说禁止无提示静默等待） |
| 2 | `content` 契约 `maxLength: 5000`（服务端安全网） | PRD/稿子的 **2000 字客户端上限今天没有任何执行点**（T5-c 未做）—— 实时字数 + 截断 + 「将基于前 2000 字生成」都还没有 |
| 3 | 标准/迷你会话对应服务端 `turn_limit`（T4 已就绪） | 客户端**两处 `createSession(materialID: nil)`**（`DefaultSpeechSessionClient.swift`），且**没有任何 UI 传 `scene_type` / 时长** |
| 4 | 迷你会话要计入北极星 | 时长二选一必须在弹层里，不能藏在二级页 |

---

## 五、当前进度（逻辑层已落地）

`Shared/FluentWorkNetworking/API/DrillModels.swift` · `Shared/FluentWorkCore/Drill/` ——
DTO（键与契约逐字对齐）+ `DrillClientProtocol` + `DrillAPIClient` + **纯状态机 `DrillRoundMachine`**。
25 条测试；变异 3 条（申诉权限 / `response_ms` 起点 / 申诉回退）**全部按预期咬住**。

**已做**（`7adda8e`）：机器已接进 Redux —— `DrillFeature`（`DrillState` / `DrillAction` /
`drillReducer`）+ `DrillMiddleware` + 数据面 `DrillClient` / `DefaultDrillClient`（不带 token）。
接法与 `speechSessionMiddleware` 同形：中间件调纯机器 → `.applyRound` 写 store → 逐条解释效应；
**5 秒限时不在视图里**（机器在 `.answering` 武装截止，到点带截止时长本身提交）。12 条判据、
7 次变异验证全部咬住。

**还没做**：本文的 UI 条目 —— 那是最后一段。它在动工之前有一份前置约定：
**[`ui-verification-strategy.md`](ui-verification-strategy.md)**（UI 里体现的功能准备怎么测，
以及为什么第一件事是**把 `state → ViewModel` 的投影从 `HostRootView` 搬进
`Shared/FluentWorkUI`** —— 它现在在 app target 里，而 app target 没有测试 target）。
