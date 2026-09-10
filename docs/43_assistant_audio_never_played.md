# 助手音频从来没被播放过

**日期**：2026-09-11  
**状态**：代码与测试已齐。门禁见 §6。  
**触发**：真机会话 `7ccb307e`（2026-09-11 02:20）——「我没有听到声音」。  
**关联**：backend `docs/49`（网关转发助手音频）· `docs/42`（子阶段超时）· meta `77_` P0-1 / P0-2

## 1. 守住的不变量

**排进播放节点的音频必须真的被播放。** 「解码器被调用过」和「用户听到了声音」是两回事,前者不蕴含后者。

## 2. 根因(两个,叠加)

### A：`playerNode.play()` 从未被调用 —— 完全无声

`LiveAudioEngine.play(frame:)` 把 PCM 解码后 `scheduleBuffer` 到 `playerNode`。而 **`playerNode` 的全部调用点是**：

```
playerNode.stop()                                   // 两处
playerNode.pause()
playerNode.scheduleBuffer(buffer, at: nil, options: []) {}
// 以及一句注释： // Do not `playerNode.play()` — interruptedBySystem already asked
```

**没有任何一处调用 `play()`。** 音频被排进一个从未启动的节点 —— 排了,永远不播。

**为什么一直没被发现**：`play(frame:)` 的注释自己写着 ——

> Queuing with a no-op completion handler returns immediately and **the audio graph is irrelevant for the assertions we make**.

**这条路径是为测试写的。** 已有的 `liveAudioEnginePlayRoutesThroughDecoder` 只断言**解码器被调用过**,不断言有任何东西播放出来。所以在网关开始转发音频之前,这个洞完全不可见。

### B：传输层丢帧 —— 即使播了也是断的

`URLSessionSocketTransport` 的事件流用 `.bufferingNewest(64)`。消费端跟不上时**丢最旧的**。

网关在**轮末一次性**推送整轮音频(10 秒回复 ≈ 106 帧),中间件逐帧解码 + 排缓冲 —— 正好是这个策略开始丢的时候。真机日志里的序号断档 `38 → 70 → 93 → 96 → 99 → 104` 就是证据。

**复现是量化的**：喂 200 帧进事件流,**只收到 64**。丢 136。

**这个策略的问题不止音频**：这条流还承载 `ai.turn.end`、`error`、`feedback.badge` —— **丢掉一个控制帧,状态机就直接卡住**。用有界缓冲去装不能丢的东西,本身就是错的。

## 3. 方案

### A：排缓冲前先把播放节点启动起来

```swift
private func startPlaybackIfNeeded() {
    attachPlayerIfNeeded()
    if !engine.isRunning { try? engine.start() }
    if !playerNode.isPlaying { playerNode.play() }
}
```

必须每次都检查,因为 `interruptNow()`(barge-in)会 `playerNode.stop()` —— 打断之后音频再到达时要能重新启动。

### B：事件流改为 `.unbounded`

```swift
AsyncStream.makeStream(of: SocketTransportEvent.self, bufferingPolicy: .unbounded)
```

**背压是 WebSocket/TCP 层的职责,不该由一个静默丢回合的缓冲来承担。**

顺带把流的构造抽成 `makeEventStream()` —— 原来策略内联在 `init` 里,**没有任何测试能碰它**,这正是它丢帧一直没被发现的原因(与 `docs/42` 里 `processingTimeouts` 不可注入是同一类问题)。

## 4. 新方案理由

- **不只是"把缓冲调大"**:64 调到 256 只是把问题推远。真实约束是"控制帧一个都不能丢",不是"缓冲多大"。
- **不用 `.bufferingOldest`**:那会在满时丢弃**新**帧 —— 对音频意味着永远听不到句尾,更糟。
- **不在 `scheduleBuffer` 后补 `play()`**:必须放在排缓冲**之前**;先排后启动会有一次静默的首帧。
- **不动 AEC**:声音都没出来之前,AEC 无从自激 —— 那条线的验证必须排在本票之后。

## 5. 影响面

- **音频**：说的房间**首次真的有声音**。这是本产品第一次能听到 AI 说话。
- **传输**：事件流不再丢帧。内存由消费速度决定 —— 消费端是一个紧凑的 `for await` 循环,且 WebSocket/TCP 本身就是背压边界。
- **状态机 / 协议**：零改动。
- **风险**：`startPlaybackIfNeeded()` 会在 `play()` 里尝试 `engine.start()`。引擎未配置时抛错被 `try?` 吞掉,行为与之前一致(静默无声),不会更糟。

## 6. 门禁

```bash
swift test                      # 416/416
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

新增测试(先红后绿,**失败输出粘贴自真实运行**)：

| 测试 | 守住的不变量 | 修复前 |
|---|---|---|
| `liveAudioEngineStartsPlaybackForScheduledAudio` | `play(frame:)` 之后播放节点处于播放状态 | `Expectation failed: await engine._testPlaybackStarted() == true` |
| `transportEventStreamDoesNotDropABurst` | 200 帧进 → 200 帧出,一帧不丢 | `Expectation failed: (received → 64) == (burst → 200)` |

为了让 A 可断言,新增了 `_testPlaybackStarted()` 测试钩子(沿用 `_testConvertToPCM16` / `_testSpeechTracker` 的既有模式)。为了让 B 可测,把事件流构造抽成 `makeEventStream()`。

## 7. 本票不做

- **不做真流式**:音频仍在轮末一次性到达(`collectTurn` 读完整轮才返回)。修好 A+B 后能听到完整的话,但仍是"AI 沉默两秒,然后一口气说完"。见 meta `77_` **P1-2**。
- **不验 AEC**:声音刚有,AEC 才第一次可测。见 meta `77_` §3.3 的受控实验。
- **不改 24k→16k 的重采样**:仍是 3:2 线性插值、无抗混叠(backend `docs/49` §明确不做)。
