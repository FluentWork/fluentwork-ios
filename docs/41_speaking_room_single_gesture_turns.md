# 说房间:一轮一次手势

**日期**：2026-09-10  
**状态**：代码与测试已齐。门禁见 §6。  
**关联**：`docs/24`（turn 超时合同,未改）、`docs/37`（等待相位与失败矩阵）、`docs/34`（I20 Item 4 手动开口）

## 1. 问题

产品形态是**一轮最多 60 秒**,但每轮要**两次点击**,而且会话页同时挂着两块做同一件事的按钮。

| # | 问题 | 位置 | 性质 |
|---|---|---|---|
| 1 | **「结束本轮」结束的是整场会话**,不是这一轮,且无二次确认 | `HostRootView.swift` 底部栏 → `.endTap` → `.endSession` | 缺陷 |
| 2 | 录音时「停止录音」与「结束本轮」同场,都是"让它停",后果不同 | 卡片 + 底部栏 | 冗余 |
| 3 | 主按钮语义横跳,且 `aiSpeaking` 那次会发 barge-in `interrupt`,界面上分不出 | `SpeakingRoomView.controlState` | 冗余 |
| 4 | `waitingForEvaluation` 一边显示「正在评价… 大约 20 秒」+ 转圈,一边亮着「开始说话」 | 同上 | 缺陷 |
| 5 | 60 秒上限没有任何可见进度,到点被 abort 才知道 | `recording` 的 `showsProgress: false` | 缺陷 |
| 6 | 每轮两次点击:「点击开始说话,说完再点停止」 | 同上 | 冗余 |

问题 1、4 与 2、3、6 是缺陷与冗余;**本票收口它们**,问题 5 见 §7。

## 2. 守住的原理

**一轮 = 一次手势。** 用户点一次开始说话,说完停顿,这一轮自动提交 —— 不再需要第二个按钮来"结束"。

**能量的职责分开**:它只负责**收轮**,不负责**开轮**。开轮永远是用户的显式动作(除非显式开启 `voiceVadAuto`)。

## 3. 方案

### 3.1 引擎:新增 `tapToStart` 模式

`SpeechBoundaryMode` 增加 `case tapToStart`,成为默认;`.manual`(两次点按)保留为回退,`.autoVAD` 语义不变。

`AudioSpeechActivityTracker` 增加 `autoStart`：

```swift
var autoStart: Bool   // false = 只有 forceStart() 能开轮,能量仍能收轮

mutating func register(energy:at:) -> AudioEngineEvent? {
    if energy >= speechThreshold {
        lastSpeechAt = now
        guard !isSpeechActive else { return nil }
        guard autoStart else { return nil }      // ← 唯一改动
        isSpeechActive = true
        return .speechStarted
    }
    guard isSpeechActive, let lastSpeechAt else { return nil }
    guard now - lastSpeechAt >= silenceHold else { return nil }
    ...
}
```

`LiveAudioEngine.updateSpeechState` 从 `guard speechBoundaryMode == .autoVAD` 改为 `guard speechBoundaryMode != .manual` —— 除回退模式外都让能量参与收轮。

`setSpeechBoundaryMode` 同步 `speechTracker.autoStart = (mode == .autoVAD)`。

中间件把默认从 `.manual` 换成 `.tapToStart`（`SpeechSessionMiddleware.swift`,`.createSession` 副作用）。

### 3.2 一个刻意的安全性质

`forceStart()` 把 `lastSpeechAt` 置 nil,而 `register` 的收轮分支要求 `lastSpeechAt != nil`。所以**点了开始却不说话,这一轮不会被自动提交** —— 它走 60 秒 abort,而不是产生一条空 turn。这是既有行为,本票没改,但正好是 tapToStart 需要的。

### 3.3 UI

- `recording`:「停止录音」→「说完了」,说明改为"停顿一下就会自动提交"
- `waitingUser`:说明改为"点一次开始说话,说完停顿一下会自动提交"
- `waitingForEvaluation`:去掉转圈(见下),标题「正在评价本次表现…」→「可以继续」
- 底部栏:「结束本轮」→「结束练习」+ `confirmationDialog`

**为什么 `waitingForEvaluation` 不能转圈**:状态机允许从该相位直接开下一轮,所以它不是阻塞态。同时显示"在忙"和"可以点"是自相矛盾。约定:**有主操作可给时不显示进度**。

## 4. 新方案理由

- **不加第三种"静音开轮"**:那等于把自动 VAD 悄悄打开,而它当初被关掉正是因为误切轮次（I20 Item 4）。开轮必须显式。
- **不删 `.manual`**:留着当回退,且已有测试覆盖它的语义。
- **不把 60 秒倒计时塞进状态机**:它是展示层的事,见 §7。
- **不把 barge-in 从 `aiSpeaking` 拿掉**:那是既有且正确的行为,本票只改文案层。

## 5. 影响面

- **状态**：`SpeechSessionMachine` **未改**。相位、事件、副作用全不动。
- **协议**：WSS 帧零改动。`user.speech.start` 仍由点击触发;`user.speech.end` 现在更多由静音触发而非点击,但帧本身不变。
- **音频**：`tapToStart` 下,点击后能量参与收轮判定 —— 这是本票唯一的行为性音频改动。
- **UI**：文案与一个确认弹窗。
- **发布**：无迁移。`voiceVadAuto` 打开时行为与之前一致。

## 6. 门禁

```bash
swift test                      # 410/410
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试：

| 测试 | 守住的不变量 |
|---|---|
| `audioSpeechActivityTrackerTapToStartIgnoresEnergyUntilTapped` | 未点击时能量不开轮;点击后可开;静音 ≥ silenceHold 收轮 |
| `audioSpeechActivityTrackerTapThenSilenceDoesNotSubmitEmptyTurn` | 点了不说不会提交空 turn |
| `speakingRoomWaitingForEvaluationOffersNextTurnWithoutProgress` | 等待评价不转圈 |
| `speakingRoomWaitingForEvaluationManualOffersStartButton` | 同上,手动模式给开始按钮 |
| `speakingRoomRecordingOffersEarlySubmit` | 录音中按钮是"提前提交"而非唯一结束方式 |

更新的既有测试（连同测试名）：`speakingRoomWaitingUserStateShowsTapToTalkByDefault`（文案）、`speakingRoomWaitingForEvaluationHidesHoldAndShowsProgress` → `...OffersNextTurnWithoutProgress`（语义反转,原名已不成立）。

## 7. 本票不做

- **60 秒可见倒计时（问题 5）**：需要把"进入 recording 的时刻"带到展示层。它不该进状态机（相位模型里没有时间),计划用 `SpeakingRoomView` 的本地 `@State` + `TimelineView` 做,不动 `SpeechSessionState`。**下一步单独做。**
- 按住说话（PTT）：已评估并否决 —— 产品允许单轮 60 秒,按住 30 秒以上手部负担过大。
- `degradedText` 的恢复路径。
