# I20 Item 4 手动开口主路径

**票**：I20 Item 4（`docs/i20-fix-plan.md` §五）。  
**状态**：已落地。自动 VAD 降级为 `voiceVadAuto`，默认关闭。  
**关联**：不是 B15；不是录音 60s abort。

## 1. 要守住的原理

一轮用户说话的起止必须是**用户点的**，不能只靠能量 VAD：

1. 等待开口时点「开始说话」→ `beginManualSpeech()` → `.speechStarted` → `user.speech.start`
2. 录音中点「停止录音」→ `endManualSpeech()` → `.speechEnded` → `user.speech.end`，**不是** `endTap`（关会话）
3. 关会话只走右上角关闭 / 底栏结束

`AppFeatureFlag.voiceVadAuto` 打开时，等待态没有按钮，仍走能量 VAD。firstWave 不打开该开关。

## 2. 根因

状态机早就有 `holdStart` / `holdEnd`，但说的房间等待态没有按钮，录音「停止」接到 `.endTap`。自动 VAD 是唯一能开口的路径，环境噪音和过早静音会误切 turn。

## 3. 方案与文件

| 文件 | 职责 |
|---|---|
| `FeatureFlags.swift` | `voiceVadAuto`，默认 false |
| `LiveAudioEngine.swift` | 默认 `.manual`，能量不发边界；`begin/endManualSpeech` 发 `.speechStarted/Ended` |
| `SpeechSessionMiddleware.swift` | 建会话时按 flag 设 `SpeechBoundaryMode` |
| `SpeakingRoomView.swift` | 手动态显示「开始说话」；`startTapIntent` / `stopTapIntent` |
| `HostRootView.swift` | start/stop 按 intent 派发 session 或 `manualSpeechBegin/End` |

PCM 仍从 tap 出；只是起止边界不再看能量。

## 4. 为何不折进已有路径

- 不改状态机：手动仍进既有 `vadSpeechStart` / `vadSpeechEnd`（由 engine 事件驱动）
- 不把停止折成 `endTap`：那会 `client.turn.abort` + 结束会话
- 不做按住-松手手势：本票是点击开始 / 点击停止，与现有 primaryAction 一致

## 5. 影响面

- 状态：等用户时可以点开始；录音停止进 processing，会话继续
- 协议：仍是 `user.speech.start/end`；flag 关时不再靠 VAD 误发
- 音频：采集图不变；手动模式能量检测不发边界
- 发布：默认说的房间是点按开口

## 6. 测试

```bash
swift test --filter "speakingRoomWaitingUser|speakingRoomRecordingStop|manualSpeech|speechActivityTrackerForce|voiceVadAuto|liveAudioEngineManualSpeech"
```
