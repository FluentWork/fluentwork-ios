# `.connecting` 没有任何超时

**日期**：2026-09-11
**状态**：看门狗与测试已齐。门禁见 §5。
**触发**：真机 —— 「点击结束练习，从工作台再次进入 speaking room，会出现 连接中」
**关联**：`docs/45`（中断悬挂）· meta `77_` F20

## 1. 守住的不变量

**每个相位都必须有出口。** 一个只能靠用户退出界面来结束的相位，不是"慢"，是没有失败路径。

## 2. 缺口：唯一没有边界的相位

中间件的定时任务覆盖了：

| 定时器 | 管什么 |
|---|---|
| `processingASRTimeout` / `processingLLMTimeout` / `processingReviewTimeout` | 处理子阶段 |
| `evaluationTimeout` | 等徽章 |
| `recordingAbortTimeout` | 录音中 |
| `reconnectWindow` | 重连 |
| `turnTimeout` | 整轮上限（B15 70s） |

**唯独没有 `.connecting`** —— 而那是**每个会话的第一个相位**。任何一步没把 `.socketReady` 送到（传输层没发事件、握手卡住、竞态吃掉事件），房间就**永远停在「连接中」**：没有超时、没有错误、除了退出去没有出路。

## 3. 关于复现，要说清楚的一件事

**本票没有复现用户那一次的具体触发，只复现了它所属的那一类失败。** 区别值得记下来：

- 后端日志里那次重进（`709bacf6`）**是成功的** —— 有 `voice user speech frame` × 2 和一条 `turn result captured`。所以卡住是**间歇**的，我没有观察到它，也没找到触发条件。
- 我能确认并复现的是：**`.connecting` 没有边界**，所以任何一次 `.socketReady` 丢失都会导致永久卡住。测试正是这么写的 —— 进入 `.connecting` 后**从不投递** `.socketReady`，在没有看门狗时以 `TimeoutError` 失败（已用"移除接线"验证红灯）。

所以：看门狗让**症状**不可能再出现（变成可重试的错误），但**底层触发仍未定性**。要定性它，需要卡住那次的 iOS tracker 日志：`speech_session_transition` 进入 `connecting` 之后**没有**对应的 `socketReady`。

## 4. 方案

```swift
if previousPhase != .connecting, newPhase == .connecting {
    effects.append(scheduleConnectWaitTask(timeouts: timeouts))
}
if previousPhase == .connecting, newPhase != .connecting {
    effects.append(.cancel(id: SpeechSessionTaskID.connectTimeout))
}
```

超时后 `.failed("连接超时，请重试")` —— 一个可重试的错误界面，而不是一块不动的屏幕。

预算 `connectWait = 10s`（`ProcessingTimeouts`，可注入）。宽松是**故意的**：它是兜底不是常见路径，握手只是一次 HTTP 加一次 WSS auth。

## 5. 门禁

```bash
swift test                      # 427/427
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试（先红后绿）：

| 测试 | 守住的不变量 | 修复前 |
|---|---|---|
| `connectingPhaseTimesOutInsteadOfStrandingTheRoom` | 进入 `.connecting` 后 `.socketReady` 不到达时必须失败，不能悬挂 | `Caught error: TimeoutError()`（等 `.failed` 等到超时） |

## 6. 顺带修掉一个测试基础设施缺陷

新测试第一版让 `transitionTelemetryEmittedOnPhaseChange` 挂了 —— 单独跑全过，一起跑必挂。

原因：`processingTimeouts` 注册是 **`.singleton`**，注册进去的 80ms `connectWait` **泄漏给了下一个 resolve 它的测试**，那个测试的房间里连接在它派发 `.socketReady` 之前就超时失败了，而它自己完全不知道为什么。

**这是既有的坑**：`processingSubStageTimeoutDoesNotFailTheSession` 早就在注册 80ms 的 asr/llm/review，只是那些值只影响它自己会走到的相位，所以没撞出可见症状。`connectWait` 是第一个影响**每个会话都会经过的相位**的注入值。

修法是在测试里 `defer` 还原 `.standard`，并在注释里写明为什么。

## 7. 本票不做

- **不追卡住的触发条件**：见 §3 —— 需要卡住那次的 tracker 日志，目前没有。
- **不缩短 `connectWait`**：它是兜底，收紧只会把慢网络变成假失败。
