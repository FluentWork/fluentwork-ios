# 结束练习确认框：确定 / 取消，打开即暂停

**日期**：2026-09-12
**状态**：实现与测试已齐。真机见 §6。

## 1. 守住的不变量

1. **弹窗挂在 `EndSessionConfirmationDialogSite.speakingRoomDestination`，并且包在相位相关 bottom bar *之前*。**
2. **打开弹窗只 `pausePlayback`：不倒队列、不拆图、不结束会话。**
3. **取消 `resumePlayback`。确定才 `endTap` → `stopCapture`。**
4. **按钮文案是「确定」和「取消」。**

打开时不停 TTS、用 `interruptNow` 倒队列、把框挂在 HostRootView 或 live 按钮上，都是事故。

## 2. 根因（三次）

| 现象 | 原因 |
|---|---|
| 确认后再开一场立刻再弹 | 框挂在 live 按钮上，`.ended` 拆掉呈现者，flag 泄漏 |
| 一点结束全屏关掉，TTS 还在响 | 框挂在呈现 `fullScreenCover` 的 HostRootView 上 |
| 点确定后闪出第二个框再自动消失 | `confirmationDialog` 挂在 `safeAreaInset(bottomBar)` **后面**。`.ended` 重建 inset，SwiftUI 把框当成新的呈现；Binding 的 `get` 因 `!isActive` 立刻变 false，所以自动消失 |
| 第一次点「结束练习」有杂音 | 弹窗出现时 TTS 仍在播；呈现本身还会碰音频图 |

## 3. 修法

- `.alert` 包在房间 ZStack 上，**先于** overlay / safeAreaInset。
- 打开：`.endSessionConfirmShown` → `pausePlayback()`（`player.pause()`，后续帧只排程不 `play()`）。
- 取消：`.endSessionConfirmCancelled` → `resumePlayback()`。
- 确定：`.endTap` → 既有 `stopCapture` 拆图。
- 相位离开 live 时仍把 `@State` 写回 false。

## 4. 测试

| 测试 | 钉什么 |
|---|---|
| `endSessionConfirmShownPausesPlaybackWithoutEndingTheSession` | 打开只 pause，相位仍是 aiSpeaking |
| `endSessionConfirmCancelledResumesPlayback` | 取消 resume，不 end |
| `endSessionConfirmShownFromIdleIsIgnored` | idle 不 pause |
| `pausePlaybackHoldsThePlayerWithoutRetiringIt` | pause 后帧仍进解码器；stopCapture 才退休 |
| `endSessionConfirmShownPausesPlaybackAndCancelResumes` | 中间件把副作用接到引擎 |
| `endSessionConfirmationDialogMustSitInsideTheCover` | 只有房间 destination 合法 |

### 修复前

```
error: type 'SpeechSessionEvent' has no member 'endSessionConfirmShown'
```

## 5. 门禁

```
swift test --filter 'endSessionConfirm|pausePlaybackHolds|endSessionConfirmationDialog'
# 7 tests passed

xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'generic/platform=iOS' build
# BUILD SUCCEEDED
```

## 6. 真机判据

TTS 播放中点「结束练习」：房间还在，框只出现一次，带「确定」「取消」，喇叭立刻静音（暂停，不是沙沙）。点「取消」从暂停处继续听。点「确定」结束会话、没有沙沙、没有第二下闪框。再开一场，框不应自动弹出。
