# 相位收敛（提交一：机械半边）

**日期**：2026-09-11
**状态**：提交一（13 → 11）已实现。**提交二（11 → 9）未做**，见 §8。
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

## 8. 未做：提交二（11 → 9）

`waitingForEvaluation` / `waitingForAIAnswer` → `processing` + 对应 stage。

按设计**必须单独提交** —— 这一半不是重命名：进入条件、定时器归属、`discardsTurnOnReconnect` 的成员都要重新表达，一旦有行为回归要能一眼看出是哪一半引入的。

设计 §3 的 `ProcessingStage` 最终有 5 个 case（本提交先落了 `asr`/`llm`/`review` 三个，`evaluation`/`aiAnswer` 随提交二进来）。
