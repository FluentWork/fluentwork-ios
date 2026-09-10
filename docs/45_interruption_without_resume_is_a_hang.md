# 系统中断不允许恢复时，会话会永久悬挂

**日期**：2026-09-11
**状态**：代码与测试已齐。门禁见 §5。
**触发**：真机 —— 「正在播放声音，上下滑动一下屏幕，然后就不再播放了，此处状态无法得知」
**关联**：`docs/22`（中断语义）· `docs/44`（播放生命周期）· meta `77_` F17

## 1. 守住的不变量

**每一个让音频停下来的路径，都必须留下一个能解释它的出口。** 一条把状态机锁死、又不发任何事件的路径，比一次明确的失败更糟 —— 失败可以重试，悬挂只能干等。

## 2. 根因：`shouldResume == false` 时什么都不发

两段代码合起来构成一个死锁。

**状态机**（`SpeechSessionMachine`）：中断开始 → 挂起并停播。

```swift
case (_, .interruptedBySystem) where isActive(state.phase) && state.suspendedPhase == nil:
    state.suspendedPhase = state.phase
    effects.append(.stopPlayback)
```

**而且挂起期间，除 5 个事件外全部丢弃**：

```swift
if state.suspendedPhase != nil {
    switch event {
    case .systemInterruptEnded, .endTap, .forceClose, .failed, .recordingTimedOut:
        break
    default:
        return []
    }
}
```

**引擎**（`LiveAudioEngine.handleInterruption`）：iOS 说"不要恢复"时，静默返回。

```swift
case .ended(let shouldResume):
    guard shouldResume else { return }        // ← 死锁在这里闭合
    continuation.yield(.systemInterruptEnded)
```

`docs/22` 的"只在 iOS 允许时恢复"本身是对的，但它被实现成了**沉默**。于是：

- 音频在 `.began` 时被 `stopPlayback` 停掉 ✅（用户听到的"不再播放"）
- `.ended(shouldResume: false)` 什么都没发 → **没有任何东西能解除挂起**
- 挂起期间所有语音事件被丢弃 → 麦克风、VAD、网络帧全部石沉大海
- UI 停在中断前的那个相位上 → **用户看到的就是"停了，而且不知道为什么"**

**这不是"谨慎"，是陷阱**：唯一能解锁的事件 `.systemInterruptEnded` 恰好是那条分支拒绝发出的。

## 3. 方案

```swift
guard shouldResume else {
    continuation.yield(.failed("音频被系统中断，本轮练习已停止"))
    return
}
```

`.failed` **在允许通过的那 5 个事件里** —— 这是它被选中的原因，不是随便挑的。它会走到状态机的 `.failed`，UI 上就是一个可重试的错误，而不是一块静止的屏幕。

仍然不发 `.systemInterruptEnded`（既有测试 `liveAudioEngineHandleEndedShouldResumeFalseDoesNotYieldSystemInterruptEnded` 继续成立）：我们确实**没有**拿到恢复许可，不能假装拿到了。

## 4. 关于"滑动屏幕"

**本次没有找到滚动与音频停止之间的因果链，这里如实记录。**

已排除：

| 嫌疑 | 结论 |
|---|---|
| 说房间的 UI 派发了会话动作 | ❌ 全文件唯一的副作用是 `.onChange(of: timeline.count)` → `proxy.scrollTo`，不派发任何东西 |
| 触觉反馈打断音频会话 | ❌ 全仓无 `sensoryFeedback` / `FeedbackGenerator` |
| 滚动间接触发 `.began` | ❌ `AudioInterruptionObserver` 只把 `interruptionNotification` 映射成 `.began/.ended`，路由变化单独走 |

**能确认的是**：只要真的发生了一次不可恢复的中断，症状与用户描述**完全一致** —— 播放停止 + 状态不可知。所以本票修的是那个症状的成因，而滚动是否只是与中断同时发生，需要下一次真机日志来分辨。

判据很明确：如果下次再出现，日志里会有 `audio_engine_failed`（本票新增的出口）或 `interruptedBySystem` 的相位转换。**没有这两条 = 我的判断不完整，需要另找路径。**

## 5. 门禁

```bash
swift test                      # 422/422
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试（先红后绿）：

| 测试 | 守住的不变量 | 修复前 |
|---|---|---|
| `liveAudioEngineReportsAnInterruptionItCannotResume` | 不可恢复的中断必须以 `.failed` 收场，否则会话挂在挂起相位上 | `an interruption iOS will not resume must surface as .failed or the session hangs suspended; got nil` |

## 6. 本票不做

- **不给挂起加看门狗**：`.ended` 一定会来（iOS 保证），所以"发了但被丢弃"这条已闭合。"从来没来"目前没有证据，加超时会是又一层猜测。
- **不改暂停期间的 UI 呈现**：`.failed` 已有可重试的呈现路径。真的需要一个"被中断"的专门界面，是产品决定。
- **不查滚动本身**：见 §4 —— 没有因果链可查，硬查就是编故事。
