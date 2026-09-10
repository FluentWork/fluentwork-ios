# 子阶段超时是诊断,不是判决

**日期**：2026-09-11  
**状态**：代码与测试已齐。门禁见 §6。  
**触发**：真机会话 `bbab2f75`（2026-09-11 02:13）——「会主动断掉」。  
**关联**：`docs/24`（turn 超时合同）· `docs/37`（等待相位与失败矩阵）· `docs/41`（说房间交互）

## 1. 守住的不变量

**客户端不得因「自己设的时延预算」结束会话。** 一轮什么时候结束,权威在网关的 `ai.turn.end`;没有它时,由 B15 的 70 秒总上限兜底。

子阶段预算(15/45/30 秒)**只用于上报**,不用于判死。

## 2. 根因

`scheduleProcessingTimeoutTask` 到点直接 dispatch `.failed`：

```swift
// 旧实现
return .task(id: cancellationID) {
    try? await Task.sleep(for: duration)
    guard !Task.isCancelled else { return nil }
    return .speakingRoom(.session(.failed(reason)))   // ← 杀会话
}
```

而这些预算与网关的等待窗口**严重不对称**：

| 侧 | 时限 |
|---|---|
| iOS `ProcessingTimeouts.asr` | **15 秒** → `.failed("processing_timeout_asr")` |
| 网关 `defaultVolcTurnWait` | **60 秒** |

**后果**:任何供应商慢过 15 秒的轮次,iOS 都会杀掉会话 —— **哪怕服务端本来能成功**。客户端把服务端的 60 秒预算变得**根本用不上**。

真机证据（会话 `bbab2f75`,02:13）：

```
02:13:39.896  网关  collect_turn.start   turn-2
              iOS  processingASR → failed   delta_ms: 15892.800     ← 客户端 15.9s 放弃
02:14:39.898  网关  collect_turn.done    duration_ms=60002
                     event_count=2, transcript_len=0, outcome=partial, err=None
```

**服务端还在等的时候,客户端已经判了死刑。** 而且注意 `outcome=partial` + `err=None` —— 按 `docs/43` 的语义,这**不是断连,是供应商不回**,连接是好的。

三个子阶段的预算相加(15+45+30=90s)本来就超过总上限 70s —— 说明它们设计上是**分段预算**,不是**分段判决**。

## 3. 方案

`scheduleProcessingTimeoutTask` 改为**上报后返回 nil**,不再 dispatch 任何事件：

```swift
tracker.track(event: trackEvent, properties: ["stage": stageName])
return nil
```

- 事件名(`processing_timeout_asr` / `_llm` / `_review`)**保持不变**,看板不用改
- 相位不动,会话继续
- 终局仍由 `ai.turn.end` 或 70 秒 `totalCap` 决定(后者本来就是 B15 的既定路径)

### 为可测试性加的注入缝

`processingTimeouts` 原本是**文件级 `private let`**,所以 15 秒的超时路径**在单测里根本无法观察** —— 这正是它一直没有覆盖的原因。

改为注册进 `Container`（`AppDependencies.swift`）：

```swift
var processingTimeouts: Factory<ProcessingTimeouts> {
    self { .standard }.singleton
}
```

中间件从容器解析一次,沿 `processingTimeoutEffects` → 各 timer 函数向下传。生产行为不变(默认 `.standard`)。

## 4. 新方案理由

- **不改成"更长但仍致命"的阈值**:那只是把问题推远。真正的错在于**客户端替服务端做终局判断**,长度怎么调都是错的。
- **不删掉子阶段预算**:它们仍然有价值 —— 超预算意味着"这一段慢得值得看一眼",埋点保留。
- **不动 `totalCap`(70s)**:那才是 B15 合同里的兜底,有明确的语义和测试。
- **不动 `recordingAbortTimeout`(60s)**:那是另一条路径(I20 abort),不在本票。

## 5. 影响面

- **状态**：`SpeechSessionMachine` **未改**。改的是 timer 到点后的动作。
- **协议**：WSS 帧零改动。
- **行为**：供应商慢于 15 秒的轮次,客户端**不再自杀** —— 会一直等到 `ai.turn.end` 或 70 秒总上限。这正是本次要修的。
- **观测**：`processing_timeout_asr/llm/review` 三个埋点事件**照旧上报**,现在它们真的只是信号。
- **发布**：无迁移。`Container.processingTimeouts` 有默认值,不注册也正常。

## 6. 门禁

```bash
swift test                      # 414/414
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试：

| 测试 | 守住的不变量 |
|---|---|
| `processingSubStageTimeoutDoesNotFailTheSession` | 注入 80ms 的 ASR 预算,超时 5 倍后相位**仍是 `processingASR`**、`failureReason` 为空、**不调 `endSession`** |

**修复前的实际失败输出**（先红后绿,粘贴自真实运行）：

```
✘ Expectation failed: (store.state.speakingRoom.phase → .failed) == .processingASR
✘ Expectation failed: (store.state.speakingRoom.failureReason → "processing_timeout_asr") == nil
✘ Expectation failed: await speechClient.endSessionCalled == false
--- Test processingSubStageTimeoutDoesNotFailTheSession() failed after 0.449 seconds with 3 issues.
```

## 7. 本票不做

- 不动 70 秒 `totalCap` 的语义（B15 合同的兜底）
- 不改网关的 60 秒 `defaultVolcTurnWait`
- 不追"火山为什么 60 秒不回" —— 那是 `77_` 里的独立条目,且需要 AEC 受控实验先排除自激
