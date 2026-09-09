# T-I21-1 会话相位：waitingForAIAnswer / waitingForEvaluation

**票**：I21 T-I21-1
**状态**：已落地（仅枚举与 label）。转换规则留给 T-I21-2。

## 1. 要守住的原理

票面写的是 V1.x「5 态 → 7 态」。当前 `SpeechSessionPhase` 已经是连接 / 录音 / ASR / LLM / Review / 降级等 **11 个相位**，不能收成 `idle / listening / processing / speaking / ended`。

本票只增加两个具名等待相位，不改 `SpeechSessionMachine` 的边。

- `waitingForAIAnswer`：turn 已发出、还在等 AI 开口（I20 abort 之后的插入态，T-I21-2 再接线）
- `waitingForEvaluation`：本轮说完、还在等评价帧

它们 **不是** processing 子阶段。`isProcessing == false`，避免 abort 后误 arm B15 70s。

## 2. 根因

I21 要的两个等待在现有相位里对不上号：abort 后现在直接回 `.waitingUser`；评价走的是 `.processingReview`（processing 超时合同内）。先把类型放进枚举，转换和 UI 细绑才能单独测。

## 3. 方案

- `SpeechSessionPhase` 增加两 case，`CaseIterable`
- `label` 与 `stageTag` 同值，新相位用 snake_case：`waiting_for_ai_answer` / `waiting_for_evaluation`
- `isActive == true`（会话未结束，`forceClose` 仍能拆）
- View / Host 底栏为通过编译补了文案，交互仍按 T-I21-3

生产缺省仍是 `Container.shared`；本票不碰 tracker。

## 4. 为何不折进现有路径

- 不把 `processing` 改回单态：ASR / LLM / Review 已经分开，B15 分阶段超时依赖它
- 不把 `waitingForEvaluation` 做成 `.processingReview` 别名：一个在 processing 合同里，一个在 turn 结束后等 eval.frame
- 不在本票写 `isValidTransition`：那是 T-I21-2

## 5. 影响面

状态机边不变。录音 abort 仍回 `.waitingUser`（`docs/24`）。音频 / WSS 不变。新增相位目前是可达的类型、不可达的运行时态。

## 6. 测试

`swift test --filter "speechSessionPhaseLabels|speechSessionPhaseIsActive|forceCloseFromRemainingActivePhases"`
