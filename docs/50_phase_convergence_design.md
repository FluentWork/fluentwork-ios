# 相位收敛：把后端管线阶段从产品语义里拆出去

**日期**：2026-09-11
**状态**：**设计。未实现。**
**对应**：meta `77_` **P1-3** · 执行计划**步 9**

## 1. 为什么

> P1-3：13 个相位超出产品语义。**这一夜 4 个真机缺陷里 3 个出在这个区域。**

"3 个出在这个区域"不是巧合，逐个看根因：

| 缺陷 | 它怎么和相位有关 |
|---|---|
| **F19** 评估超时剪掉话尾 | `.stopPlayback` 挂在 `(.waitingForEvaluation, .evaluationTimedOut)` 上 —— **一个后端定时器变成了用户可见的行为**（播放被掐掉）。兄弟分支 `evaluationReceived` 落同一相位却不停播，两条路径的行为差异没有任何语义依据 |
| **F20** `.connecting` 是唯一没有超时的相位 | 定时器是**按相位**配置的。少写一个相位的条目 = 那个相位**没有超时、没有错误、永不出来**。相位越多，这个漏法越多 |
| **F17** 不可恢复的中断 = 静默悬挂 | `.began` 期间状态机丢弃除 5 个事件外的**全部**输入，而唯一能解锁的事件恰好在那 5 个之外。挂起逻辑要枚举"哪些相位允许什么"，枚举面随相位数量增长 |

共同点：**相位在承载实现细节，而实现细节会变、会漏、会被无关地耦合。**

## 2. 现状：五个"相位"其实是一条后端管线

```
recording ──► processingASR ──► processingLLM ──► processingReview ──► waitingForEvaluation ──► waitingUser
                    │                │                 │
                    └────────────────┴─────────────────┴──► aiSpeaking   (aiFirstAudioChunk)

recording ──► waitingForAIAnswer ──► waitingUser          (I21：客户端文本为空的支路)
```

**这五个没有一个是产品状态。** 对用户来说它们是同一件事：**"系统正在处理你刚说的这句。"**

它们之间的差别全是**后端在哪一步**：

- `processingASR` / `processingLLM` / `processingReview` —— 后端管线的三个阶段
- `waitingForEvaluation` —— 后端评分器还没回
- `waitingForAIAnswer` —— 走的另一条入口（空 ASR 文本），等的是同一件事

而 `processingSubStage`（`.asr` / `.llm` / `.review`）**已经存在**，只是它是从相位**派生**出来的：

```swift
public var processingSubStage: ProcessingSubStage? {
    switch self {
    case .processingASR: return .asr
    ...
```

**一份信息存了两遍**：相位是主，子阶段是影。收敛就是把影子扶正 —— 子阶段成为数据，相位回归产品语义。

## 3. 目标：13 → 9

| 保留（产品语义） | 说明 |
|---|---|
| `idle` | 不在会话里 |
| `connecting` | 正在连 |
| `aiSpeaking` | **AI 在说** |
| `waitingUser` | **轮到你** |
| `recording` | **正在采集你说话** |
| `processing` | **正在处理你这轮**（由 5 个合并） |
| `degradedText` | 退化为文字 |
| `ended` / `failed` | 终态 |

```swift
public enum ProcessingStage: String, Equatable, Sendable, Codable {
    case asr          // 原 processingASR
    case llm          // 原 processingLLM
    case review       // 原 processingReview
    case evaluation   // 原 waitingForEvaluation
    case aiAnswer     // 原 waitingForAIAnswer
}
```

`processingStage` 成为 `SpeechSessionState` 上的**存储字段**，只在 `phase == .processing` 时非 nil。相位与阶段的不变量由构造点保证，不再是派生。

### 合并两个"等待"的理由

它们是**风险最高的两个**，也恰恰是最该合并的。

`waitingForEvaluation` 存在的唯一理由是"后端评分器有自己的计时"。**让一个有自己计时的东西拥有一个相位，就等于让定时器拥有用户可见行为** —— F19 就是这么发生的。合并之后，定时器只能通过 `state.processingStage == .evaluation` 被判断，读起来就是它本来的样子：**"这是后端计时，不是产品状态。"**

`waitingForAIAnswer`（I21）同理：它是**入口不同、等待相同**。

## 4. 迁移：两次提交，各自可验证

不要一次做完。分成机械的和语义的两步，每步单独跑测试。

### 提交一（机械）

`processingASR` / `processingLLM` / `processingReview` → `processing` + `processingStage`。

这一半**是重命名**：`.processingASR` → `.processing`，`phase.processingSubStage == .asr` → `state.processingStage == .asr`。~62 处引用，集中在 `SpeechSession/`、`Architecture/Middleware/`、`FluentWorkUI/SpeakingRoom/`。

**验收：相位 13 → 11，测试一条不少**（改的是断言写法，不是断言内容）。

### 提交二（语义）

`waitingForEvaluation` / `waitingForAIAnswer` → `processing` + 对应 stage。

这一半**不是重命名**：进入条件、定时器归属、`discardsTurnOnReconnect` 的成员都要重新表达。**必须单独提交**，因为一旦有行为回归，要能一眼看出是这一半引入的。

**验收：相位 11 → 9，测试一条不少。** 特别地，F19 的守卫测试（评估超时**不**停播）必须原样通过 —— 它守的行为不变，只是表达方式从"相位"变成"阶段"。

## 5. 要一起处理的耦合点

收敛不能只改枚举，这几处是列出相位名的地方，**每一处都是将来漏一个相位就出 bug 的点**：

| 位置 | 现在 | 收敛后 |
|---|---|---|
| `discardsTurnOnReconnect` | 逐个列相位 | 按 `isActive` + stage 表达 |
| `isActive` | 逐个列相位 | 保持（收窄到 9 个更容易看全） |
| `stageTag` | 相位 → 后端 stage 串 | `processing` 要带上 stage 才有区分度 |
| 各定时器 | 按相位配 | 按相位配（相位少了，漏法少了） |
| `suspendedPhase` | 存相位 | 不变，但需要一并存 stage |

**`stageTag` 是个真问题**：后端日志靠它对齐。合并之后 `processing` 需要映射到后端那三个不同的 stage 串，所以 `stageTag` 必须读 stage 而不只是 phase。**这是收敛里唯一会影响跨服务日志的地方**，要在实现时先确认后端那三个串的取值。

## 6. 测试策略：数量不减

验收是"**相位数量下降，测试不减少**"，所以：

- `SpeechSessionMachineTests`（596 行）里的相位断言**改写不删除**：`XCTAssertEqual(state.phase, .processingASR)` → `XCTAssertEqual(state.phase, .processing)` + `XCTAssertEqual(state.processingStage, .asr)`
- **每条被合并的相位，它的转移测试都必须还在** —— 收敛的诱惑是"相位没了，测它干嘛"，而那正好会把 F19 这类守卫一起删掉
- 新增守卫：**`processingStage` 只在 `phase == .processing` 时非 nil**（相位与阶段不漂移）

## 7. 本设计不做

- **不删任何相位**：`ended` / `failed` / `degradedText` 都是产品语义。
- **不动 `suspendedPhase` 的机制**：F17 的修法是另一件事，收敛只是让它要枚举的面变小。
- **不改后端**：后端那三个 stage 串是日志契约，收敛只改 iOS 侧怎么表达。
- **不与音频流式混做**：meta `77_` P1-2 的音频半边（`docs/55` §7）需要带状态的重采样器，是独立的一块。

## 8. 为什么这份文档先于实现

**改动面 ~62 处引用，跨状态机 / 中间件 / 视图 / 5 个测试文件，而它动的是"4 个真机缺陷里 3 个出在其中"的那个状态机。**

这类改动**要么一次做完，要么不做** —— 留半个收敛后的状态机（一部分相位合并了、一部分没有）比现状更难推理，因为它会让"相位"这个概念同时有两种含义。

所以顺序是：**先有设计并评审，再动手**。这份文档就是那个前置件。
