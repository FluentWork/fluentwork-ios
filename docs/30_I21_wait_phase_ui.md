# T-I21-3 等待相位 UI

**票**：I21 T-I21-3
**状态**：已落地。

## 1. 要守住的原理

`waitingForAIAnswer` 是 abort 落点（会话仍活，不是加载态）。`waitingForEvaluation` 是加载态。都不是终态。

I20 Item 4 之后：默认手动态（`voiceVadAuto` 关）显示「开始说话」；`usesAutoVAD == true` 时按钮仍隐藏，用户靠能量 VAD 开口。详见 `docs/34_I20_manual_speech_boundary.md`。

文案：

- `waitingForAIAnswer`：`本轮已超时`（abort 落点，不是加载态；无 10s timer）
- `waitingForEvaluation`：`正在评价本次表现…`（约 20s；`feedback.badge` 或超时后回「轮到你了」）

## 2. 根因

T-I21-2 让这两个相位运行时可达。没有独立文案时会误用 processing 或 waitingUser 的控件。

## 3. 方案

`SpeakingRoomViewModel.controlState`：abort 落点 `showsProgress == false`、手动态有「开始说话」；评价等待 `showsProgress == true`。Host 底栏「结束本轮」覆盖这两个相位。

## 4. 为何不折进现有路径

不复用 `.processingLLM`「思考中」：那是 processing 合同，会 arm 分阶段超时。等待态 `isProcessing == false`。

## 5. 影响面

只改说的房间控件文案。状态机 watchdog / 重连见 `docs/37`。

## 6. 测试

`swift test --filter "speakingRoomWaitingForAIAnswer|speakingRoomWaitingForEvaluation"`
