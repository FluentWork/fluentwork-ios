# T-I21-2 等待相位转换规则

**票**：I21 T-I21-2
**状态**：已落地。

## 1. 要守住的原理

票面 8 条边是 V1.x 五态图。当前机器不能收成 `idle/listening/processing/speaking/ended`。合法转换按 **现有 13 相位** 写 `isValidTransition`，reduce 之后再 guard 一次；非法 hop 整单回滚。

两条新边：

- `.recording` + `.recordingTimedOut` → `.waitingForAIAnswer`（I20 abort，会话继续，不 arm B15）
- processing / `.aiSpeaking`（`userTurnCount > 0`）+ `.aiTurnEnd` → `.waitingForEvaluation`
- 开场 greeting：`.aiSpeaking` 且尚未开口 + `.aiTurnEnd` → `.waitingUser`

离开等待：

- 两个等待态都可以 VAD / hold 进 `.recording`
- `.evaluationReceived`：`.waitingForEvaluation` → `.waitingUser`
- `endTap` / `forceClose`：等待态 → `.ended`

B15 的 `ai.turn.end outcome=timeout` **不走** 这条图，仍由 middleware 派发 `.failed("turn_timeout")` 杀会话。

## 2. 根因

T-I21-1 只有类型。abort 仍回 `.waitingUser`，正常 `ai.turn.end` 也直接回 `.waitingUser`，两个等待相位运行时不可达。

## 3. 方案

- `SpeechSessionMachine.isValidTransition(from:to:)`：allow-list，含打断恢复 `* → waitingUser`、`isActive → ended/degradedText`、`!= ended → failed`
- 新事件 `.evaluationReceived`（eval.frame 未到之前，下一轮开口也能离开评价等待）
- 机器仍纯函数；埋点继续 `.trackTransition`，不在 reduce 里打 tracker

## 4. 为何不折进现有路径

- 不把 abort 接到 `.failed("turn_timeout")`：那是 B15
- 不把 `.ended` 改成 turn 终态再叠 `waitingForEvaluation`：`.ended` 仍是会话终态
- 不把 `waitingForEvaluation` 做成 `.processingReview`：processing 合同里的 review 仍 arm 分阶段超时

## 5. 影响面

状态机边变了：abort 落点、正常 turn 结束落点。音频 / WSS 不变。`eval.frame` 还没有时，用户开口即可离开评价等待。

## 6. 测试

`swift test --filter "waitingForAIAnswer|waitingForEvaluation|isValidTransition|recordingTimedOutAborts|aiTurnEndHappyPathGreeting|bootstrapAITurnEnd"`
