# 传输层丢弃是静默的

**日期**：2026-09-11
**状态**：可观测性与播放入队已改。门禁见 §5。
**触发**：真机 —— 「返回的语音播放不全，有时候是前半段，有时候是后半段，这一次没有上下滑动 UI」
**关联**：backend `docs/50`（F18）· `docs/45`（中断悬挂）· meta `77_` P1-7

## 1. 守住的不变量

**音频帧被丢弃时，必须留下一条能说出原因的记录。** 一个把整轮音频前半段吃掉、却不发任何事件的过滤器，会让"播放不全"这种报告查无可查。

## 2. 症状的成因：两个门禁，都是整场生命周期

客户端有**两道**barge-in 水位线，彼此独立，而且**都只在会话级重置**：

| 门禁 | 位置 | 置位 | 清除 |
|---|---|---|---|
| `AudioPlaybackGate.interruptWatermark` | `LiveAudioEngine` | `interruptNow()` | `startCapture()` / `stopCapture()` |
| `AudioFrameDropGate.interruptMaxSequence` | `URLSessionSocketTransport` | `transport.markInterrupted()` | **只有 `connect()`** |

第二道的 `clearInterrupt()` **在生产代码里零调用** —— 只有定义和测试。也就是说它一旦被设下，**整个连接期间永不清除**。

叠加当时**尚未修复的后端**（`docs/50`：透明重开会把序号从 1 重来），就得到用户的症状：

```
barge-in            → 水位线 = W
网关重开（约每轮一次） → 序号从 1 重来
传输层丢弃 sequence <= W → 新一轮的 1..W 被丢在到达引擎之前
                        → W+1.. 才播
```

`W` 小就听到大半（「前半段」），`W` 大就只剩尾巴（「后半段」）。**不需要滑动** —— 触发条件是重开，不是滚动。

**当时跑的后端不含 F18**：voice-gateway 进程启动于 02:11:55，F18 提交于 02:53:29。

## 3. 方案：把丢弃变成可查

不改变门禁行为（水位线的生命周期是 P1-7，单独一票），只让它**说话**。

```swift
case audioFrameDropped(sequence: UInt32, watermark: UInt32, dropped: Int)
```

规则抽成 `AudioDropReport`（纯类型，可脱离 socket 测试）—— 与 `AudioFrameDropPolicy` 从 `AudioFrameDropGate` 抽出来是同一个理由：

- **run 开始时报一次**：第一帧被丢就要可见。
- **run 结束时再报一次**，带上丢了多少帧。
- **一个永远不结束的 run 也必须报**：那正是最坏情况（水位线把它之后的一切都压住），不能恰好是唯一什么都不报的情形。

中间层把它落成 tracker 事件 `transport_audio_dropped`。

判据因此从"猜"变成"读"：**`sequence` 小于等于 `watermark`，却出现在设下水位线那一轮之后 —— 这就是网关序号回退的签名。**

## 4. 顺带：`scheduleBuffer` 的编辑器提示

`playerNode.scheduleBuffer(buffer, at: nil, options: []) {}` 在 Xcode 里提示「Consider using asynchronous alternative function」。

**不能换成 async 版本**：`await scheduleBuffer` 要等缓冲区**渲染完**才返回。网关在**轮末一次性**推整轮音频（32 秒的回复 ≈ 320 帧），await 会把中间件的传输循环按实时速率卡住 32 秒 —— 文字帧、控制帧、下一轮音频全排在它后面。

改为同步的 `enqueueWithoutWaiting(_:)` + `completionHandler: nil`：队列不需要完成回调，而那个提示针对的正是"在 async 上下文里传闭包"。两者都不再成立。

## 5. 门禁

```bash
swift test                      # 425/425
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试（本票是**可观测性新增**，无"修复前失败"可复现；测试锁定的是期望行为）：

| 测试 | 守住的不变量 |
|---|---|
| `audioDropReportAnnouncesTheRunThenClosesWithTheLoss` | 首帧报一次、同 run 不重复、收尾带上丢失帧数 |
| `audioDropReportKeepsAnUnclosedRunVisible` | 永不结束的 run 也可见 —— 最坏情况不能是唯一沉默的情形 |
| `audioDropReportResetStartsAFreshRun` | 新水位线是新的 run |

## 6. 本票不做

- **不改水位线的生命周期**：那是 P1-7，需要"被打断那一轮何时真的结束"的可靠信号。本票只让它可见。
- **不加"序号变小就重置"的启发式**：会在真正的乱序场景下帮倒忙，并藏起真 bug。见 P1-7。
