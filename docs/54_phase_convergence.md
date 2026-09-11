# 相位收敛：把后端管线阶段从产品语义里拆出去（13 → 9）

**日期**：2026-09-11
**状态**：两半都已实现。**13 → 9**（提交一 13 → 11，提交二 11 → 9）。
**对应**：meta `77_` **P1-3** · 执行计划**步 9** · 设计 [`50_phase_convergence_design.md`](./50_phase_convergence_design.md)

## 1. 做了什么

`processingASR` / `processingLLM` / `processingReview` 三个相位合并成 `processing`，管线位置变成 `SpeechSessionState.processingStage` 上的**存储字段**。

**13 → 11。** 合并的是三个"相位"，不是三个能力 —— 它们对用户是同一件事："系统正在处理你刚说的这句。"

关系被**倒过来了**：以前相位是主、`processingSubStage` 是派生出来的影子（`SpeechSessionState.init` 里 `phase.processingSubStage` 兜底）；现在 stage 是数据，相位是产品状态。

## 2. 设计文档的前置条件：答案是"三个里只有一个存在"

设计 §5 写着「实现前先确认后端那三个 stage 串的取值」。核完了，结论比预期更值得记：

| iOS 标签 | 后端是否有生产者 |
|---|---|
| `asr` | **有**（`voicegateway/handler.go:504,592`、`voicepoc/volc_duplex.go:270`） |
| `llm` | **没有** |
| `review` | **没有** |

后端全仓产出的 `stage` 值只有五个：`orchestration` / `asr` / `tts` / `scheduler` / `transport`。

所以设计里"stageTag 是唯一影响跨服务日志的契约"这个前提，**一半是虚构的** —— 这正是 `77_` **P1-20** 记的"只兑现 3/13"。

**它不改变本票的做法**：iOS 侧的三个串保留原样（`asr`/`llm`/`review`），因为它们本来就是 iOS 的标签而不是后端的回显。**没有后端改动**，设计的"不改后端"立场成立。但"先确认后端取值"这个动作的产出是**一个否定的答案**，这件事本身要记下来 —— 下一个读设计的人不该以为那里有个待确认的契约。

## 3. 一个设计没覆盖的决定：阶段推进不再产生转移事件

合并的直接后果：**ASR → LLM 不再是相位变化**。

原来的 `trackTransition(from: .processingASR, to: .processingLLM)` 驱动两条日志：`phase_transition`（timings）与 `speech_session_transition`（tracker）。合并后 `from == to`，这个 effect 根本不会发出 —— 于是 `timing_phase_transition` 会**停在"进入 processing"**，LLM / review 两跳再也不出现。

**这不能不管**：一个"静默停止运行的管线步骤"与"从未运行过的步骤"在日志里完全同形 —— 而那正是 `77_` **P1-15** 记的失败形状（`processingReview` 有消费、有测试、没有生产者）。收敛的目标是让相位不再承载实现细节，不是让实现细节变得不可见。

所以 `trackTransition` 多带一个字段：

```swift
case trackTransition(
    from: SpeechSessionPhase,
    to: SpeechSessionPhase,
    stage: ProcessingStage?
)
```

- 相位变化时：`stage` 是新状态的 stage
- **阶段推进时：`from == to == .processing`，`stage` 说明走到了哪一步** —— `from == to` 本身就是"这不是相位变化"的信号

日志里 `stage` 属性取 `stage?.stageTag ?? to.stageTag`，所以**非 processing 的转移一个字没变**，而 processing 的转移拿到的还是原来那三个串。

`speech_session_transition` 的 `from_label` 刻意**不**用 stage 回填：阶段推进时 `from == to`，回填会**把终点报成起点**。`to_label` 用 stage 解析 —— 那一半才回答"现在在哪"。

## 4. 定时器交接：从相位改到 stage

`processingTimeoutEffects` 里的子阶段交接：

```swift
// 旧：previousPhase == .processingASR, newPhase == .processingLLM
if previousStage == .asr, newStage == .llm { ... }
```

**这是本票唯一改了行为的地方**，而且是必须改：阶段推进不再是相位变化，按相位写的交接条件在新世界里**永远不成立** —— ASR 的预算会一直数进 LLM 阶段，而 LLM 的预算永远不会被装上。后者是静默的：它存在的意义是报告超预算，而不装等于永远不报告。

（这条在写完之后才被红验证发现是**没有守卫**的，见 §6 第二次红验证。）

## 5. 相位 / 阶段不变量

设计 §6 要求的新守卫：

```swift
let holds = (state.phase == .processing) == (state.processingStage != nil)
```

它由一段**真实事件序列**驱动（从 `idle` 走到 `endTap`），而不是对手工构造的状态断言 —— 会漂移的是 reducer 的分支，手工构造的状态只能测到初始化器。

`SpeechSessionState.init` 只做**单向**归一：`phase != .processing` 时把 stage 抹成 nil（stage 活得比相位久是漂移）。反方向**不做**：`.processing` 而 stage 为 nil 是调用方的错，留着可见，不猜一个填上。

## 6. 门禁与红验证

```bash
swift test          # 456 tests passed  (453 + 3 新增, 0 删除)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

**F19 的守卫测试（`evaluationTimeoutEndsTheTurnWithoutCuttingPlayback`）原样通过** —— 未改一字。它守的行为（评估超时**不**停播）与相位数量无关，这正是设计要的验收。

### 第一次红验证：抓出一条**空洞的守卫**（我自己刚写的）

破坏：`(.processing, .aiTurnEnd)` 分支去掉 `state.processingStage = nil`（制造漂移）。

**结果：全绿。守卫没咬住。**

原因是那段事件脚本**从来没有从 `.processing` 经 `aiTurnEnd` 出去** —— 它走的是 `aiFirstAudioChunk`。一条够不到自己要守的分支的守卫，正是纪律里说的"空洞的守卫：给出虚假的安全感"。

补上出口后，同一个破坏：

```
✘ Test processingStageIsNonNilExactlyWhileProcessing() recorded an issue at
  SpeechSessionMachineTests.swift:646:9: Expectation failed: holds
↳ phase/stage drifted after aiTurnEnd from .processing:
  .waitingForEvaluation/Optional(FluentWorkCore.ProcessingStage.review)
```

脚本现在覆盖 `.processing` 的**四个出口**：`aiTurnEnd`、`aiFirstAudioChunk`、重连、`networkDegraded`。

### 第二次红验证：抓出一条**没有守卫的行为**

破坏：把定时器交接条件改成 `if false, ...`。

**结果：全绿 —— 456 条测试没有一条覆盖它。** 而这是本票唯一改行为的地方。

原来的相位版本同样没有守卫（所以这是既有空白，不是本次引入），但它被改到了代码里，而设计的前提恰恰是"相位与定时器的耦合是 bug 的藏身处"（F19 与 F20 都出自这里）。补了 `pipelineAdvanceHandsTheSubStageTimerFromASRToLLM`，两半都断言：

```
✘ Test pipelineAdvanceHandsTheSubStageTimerFromASRToLLM() recorded an issue at
  SpeechSessionMiddlewareTests.swift:791:9: Expectation failed:
  (tracker.events.filter { $0.name == "processing_timeout_asr" } →
   [Event(name: "processing_timeout_asr", properties: ["stage": "asr"])]).isEmpty → false
↳ the ASR budget kept running into the LLM stage — the handoff did not cancel it
```

断言顺序对应可观测顺序：**过了 ASR 预算但没到 LLM 预算**时不应有 `processing_timeout_asr`（证明取消），**过了 LLM 预算**后必须有 `processing_timeout_llm`（证明装上）。只断言前一半会漏掉"交接发生了但没装定时器"。

## 7. 影响面

| 维度 | 影响 |
|---|---|
| **协议 / 线格式** | **无改动**。不动帧、不动后端、不动 `stageTag` 的字符串 |
| **状态机** | 相位 13 → 11；`.processing` 的进入/退出路径不变；**转移图合法边按合并后的相位重新表达** |
| **定时器** | 交接条件从相位改到 stage（行为等价，表达方式变了）—— 这是唯一的行为相关改动 |
| **可观测性** | `trackTransition` 多带 `stage`；`phase_transition` / `speech_session_transition` 对非 processing 转移**逐字不变**；processing 转移拿到的 stage 串与合并前相同。阶段推进**从"不产生事件"变成产生事件** —— 严格增量 |
| **UI** | `SpeakingRoomViewModel` 多一个 `processingStage`；三种文案（识别中/思考中/生成评价中）不变，只是按 stage 选；stage 为 nil 时回落到"处理中"而不是猜 |

## 8. 提交二（语义半边）：11 → 9

`waitingForEvaluation` / `waitingForAIAnswer` → `processing` + stage `evaluation` / `aiAnswer`。

**相位 13 → 9，测试 456 条一条不少。** 这一半不是重命名，三处必须重新表达：

| 要重新表达的 | 原来 | 现在 |
|---|---|---|
| 进入条件 | `(.waitingForEvaluation, .evaluationReceived)` | `(.processing, .evaluationReceived) where stage == .evaluation` |
| 定时器归属 | `previousPhase != .waitingForEvaluation, newPhase == .waitingForEvaluation` | `previousStage != .evaluation, newStage == .evaluation` |
| **`discardsTurnOnReconnect` 的成员** | 相位属性 | **状态属性 + 按 stage 分** |

### 为什么 `discardsTurnOnReconnect` 必须变成 stage-aware

这是收敛里唯一一个**语义真正变复杂**的地方，也是"合并"这个动作的代价所在。

它要分开的两件事，此前各自拥有一个相位：

- `waitingForEvaluation` → **丢弃**这一轮
- `waitingForAIAnswer`（I21 中止落点）→ **不丢弃** —— 用户已经放弃了那一轮，没什么可丢的，而停播会**掐掉他们还欠着的那句回答**

合并成一个相位之后，这个区分**没有别的地方可以放**。所以它从 `SpeechSessionPhase` 搬到了 `SpeechSessionState`，按 `processingStage` 判。

红验证给出了它的真实后果：把 `.processing` 一律当成丢弃 ——

```
✘ Test reconnectSucceededFromTheAbortLandingPadKeepsIt() recorded an issue at
  SpeechSessionMachineTests.swift:603:5: Expectation failed:
  (state.phase → .waitingUser) == .processing
✘ …:606:5: Expectation failed:
  !((effects → [trackTransition(processing→waitingUser), stopPlayback]).contains(.stopPlayback) → true)
```

即中止落点会被降级成 `waitingUser` 并**停播** —— 正是"掐掉欠着的那句回答"。

### `processingReview` 的真实身份（顺带核实）

合并掉的两个相位里，`processingReview` **在生产里从来没被进入过**：唯一入口 `(.processingStageReached(.review))` 全仓只有测试在派发，生产代码一处都没有 —— 正是 `77_` **P1-15**。后端也从不发 `review` 这个 stage。

对比：`processingLLM` 是**活的**（由 `client.asr.transcription` → `serverASRReceived` 进入），`processingASR` 是入口。

所以这次合并掉的三个里，**只有一个（review）是从来没跑过的** —— 它不是被"合并"了，是被**登记成数据**了。

## 9. 提交二的门禁与红验证

```bash
swift test          # 456 tests passed  (与提交一相同, 0 删除)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

**F19 的守卫测试仍未改一字**（`git diff` 确认该测试未被触碰）—— 它守的行为与相位数量无关。

### 写代码时撞出来的一个真 bug

`abortOpenRecording(&state, ...)` **会清 stage**（它结束一轮）。第一版把它写在设置落点**之后**：

```swift
state.phase = .processing
state.processingStage = .aiAnswer
effects.append(abortOpenRecording(&state, outcome: .timeout))   // ← 把 stage 清掉了
```

结果落点静默读成"没有 stage"。5 条测试同时红。修法是**先 abort 再设落点** —— 与其余 recording 终端的写法一致。

### 第三次红验证才让不变量守卫真正咬住

这一段值得单独记，因为**同一个错误犯了三次**：

| 次 | 撤销的破坏 | 结果 |
|---|---|---|
| 1 | 去掉 `(.processing, .aiTurnEnd)` 的 `stage = nil` | **全绿** —— 脚本从没从这个分支出去 |
| 2 | 补了出口之后再测同一破坏 | 红，输出点名 `aiTurnEnd from .processing` |
| 3 | 提交二的 `recordingTimedOut` 顺序 bug | **守卫仍全绿** —— 脚本先走到 `degradedText`，而 `vadSpeechStart` 在 `degradedText` 是 no-op，**再也没回到 `.recording`**，那个分支根本没被进入 |
| 4 | 重排序列（从 `waitingUser` 起新轮次）后再测 | 红，输出点名 `recordingTimedOut from .recording` |

```
↳ phase/stage drifted after recordingTimedOut from .recording: .processing/nil
```

**教训**：手写事件脚本的守卫，只覆盖**这条路径恰好走到**的分支。"走一遍看看"不是覆盖策略 —— 它会安静地跳过它对状态理解的偏差所在的那一段，而那正是唯一值得测的部分。不变量守卫的价值全在**覆盖**上，而覆盖必须**逐个出口核对**，不能靠"我走了一圈"。

（这个 bug 本身被 5 条专门的 aiAnswer 测试抓住了 —— 不变量守卫不是唯一防线。但一条声称"相位与阶段不漂移"的守卫在真漂移时全绿，那它就是装饰。）

## 10. 收敛之后：统计口径（回答"粒度是不是变粗了"）

**没有变粗**，因为阶段现在是**数据**：

| 以前靠 | 现在靠 |
|---|---|
| 相位名 `processingLLM` | `state.processingStage == .llm` |
| `trackTransition(from:to:)` | `trackTransition(from:to:stage:)` 的 **`stage`** |
| `phase.stageTag` | `state.stageTag`（stage 优先） |

`timing_phase_transition` / `speech_session_transition` 的**条数与标签都没少**（阶段推进也发事件），`stage` 拿到的还是原来五个串。

**要改的是消费侧**：阶段推进时 `from == to`，所以按 `from`/`to` 切分的日志查询要改成按 **`stage`** 切分。这是改一行查询，不是丢粒度。

**分步耗时现在有两路现成的**：

1. `SpeechSessionTimingsRecorder` 每次 mark 都发 `delta_ms` / `total_ms` / `prev_event`，所以 `stage=llm` 那条的 `delta_ms` **就是 ASR 那一步的耗时** —— 逐步相减，无需新埋点
2. `processing_timeout_asr/_llm/_review` 三个事件本来就带 `stage`，且已有交接守卫

**要显式的"每步耗时一行"是新增能力**（在 stage 推进分支附一条 `stage_exited(stage, duration_ms)`），不是补回归。

**一处真实的口径变化**：`ProcessingStage` 现在混了两类 —— **管线步骤**（`asr`/`llm`/`review`）与**等待状态**（`evaluation`/`aiAnswer`）。要"用户在'处理中'看了多久"用整个 `.processing` 相位（比改革前更准，以前要加 5 个相位）；要"ASR 用了多久"按 stage 过滤。两种口径都表达得出，且分得更清楚；代价是任何**直接读相位 rawValue**（按 `"processingASR"` 字符串匹配）的外部消费者会失效 —— 日志里的 `stage` 带着同样的信息。
