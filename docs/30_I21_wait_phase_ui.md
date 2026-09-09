# T-I21-3 等待相位 UI

**票**：I21 T-I21-3
**状态**：已落地。

## 1. 要守住的原理

`waitingForAIAnswer` / `waitingForEvaluation` 是会话仍活的加载态，不是终态。Hold / 开始按钮隐藏；用户仍可用 VAD 开口进入下一轮。

文案：

- `waitingForAIAnswer`：`AI 思考中…`（最长约 10s）
- `waitingForEvaluation`：`正在评价本次表现…`

## 2. 根因

T-I21-2 让这两个相位运行时可达。没有独立文案时会误用 processing 或 waitingUser 的控件。

## 3. 方案

`SpeakingRoomViewModel.controlState` 两 case：`showsProgress == true`，`primaryAction == nil`。Host 底栏「结束本轮」在 T-I21-1 已覆盖这两个相位。

## 4. 为何不折进现有路径

不复用 `.processingLLM`「思考中」：那是 processing 合同，会 arm 分阶段超时。等待态 `isProcessing == false`。

## 5. 影响面

只改说的房间控件文案。状态机 / 音频 / WSS 不变。

## 6. 测试

`swift test --filter "speakingRoomWaitingForAIAnswer|speakingRoomWaitingForEvaluation"`
