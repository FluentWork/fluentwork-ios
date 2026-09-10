# 录音窗口外的 PCM 不再上行

**日期**：2026-09-10  
**状态**：代码与测试已齐。门禁见 §6。  
**关联**：`docs/24_voice_turn_timeout_contingency.md`（§5.4 契约已同步更新）· `docs/20_I20_voice_turn_boundary_pitfalls.md`  
**触发**：2026-09-10 真机火山日志（session `cbfa2d23`）turn-3 用 2.9s 的按住时长换回 83 字的 transcript。

## 1. 守住的不变量

**PCM 只在用户已开口（`user.speech.start` 已出站、尚未收轮）的区间内上行。**

麦克风 tap 从 `startCapture()` 一直跑到会话结束，与"用户是否正在说一轮话"无关。旧实现让 `shouldForwardPCM` 除 abort 外恒为 true，等于把整段会话的麦克风音频都推给网关。

## 2. 根因

`SpeechCaptureGate.shouldForwardPCM` 只由 `dropPCMUntilNextSpeech` 决定，而该标志**只有 `abort()` 会置位**：

```swift
// 旧实现
var shouldForwardPCM: Bool {
    storage.withLock {
        if $0.dropPCMUntilNextSpeech && !$0.open { return false }
        return true
    }
}
```

`beginSpeech()` / `endSpeech()` 都只动 `open`。于是：

1. 首次 `beginSpeech()` 之后，PCM 永不停发
2. 网关在 `user.speech.end` 时对该轮做 `CommitAudio` → `collectTurn`
3. 供应商的 transcript 覆盖 **上一次 commit 到本次 commit 之间的全部音频**，而不是客户端 tap 的窗口
4. 用户在两轮之间说的话，被并进**下一轮**

**真机证据**（`asr_started_ms` 恒等于整轮时长，说明转录在 commit 那一刻才启动，覆盖的是整个累积窗口）：

| 轮次 | tap 窗口 | 距上次 commit | transcript |
|---|---|---|---|
| turn-1 | 7.05s | 16.2s | 15 字节 |
| turn-2 | 2.04s | 21.5s | 34 字节 |
| turn-3 | **2.93s** | **33.5s** | **249 字节（83 字）** |

turn-3 是决定性的：按住 2.9 秒不可能产出 83 个字的语音。

这条契约写在 `docs/24` §5.4 里并注明"保持历史行为"。它成立的前提是**自动 VAD 模式**——那时"非说话区间"本就是要送给供应商做端点检测的。而 `voiceVadAuto` 默认关闭（I20 Item 4 起默认点按说话），前提不再成立。

同一个文件里的客户端 ASR 缓冲路径（`isCapturingSpeech`）本来就只覆盖说话窗口，PCM 前向是唯一的例外。

## 3. 方案与文件

| 文件 | 职责 |
|---|---|
| `Shared/FluentWorkCore/Architecture/Middleware/SpeechSessionMiddleware.swift` | `SpeechCaptureGate.shouldForwardPCM` 改为读 `open`；删除随之失效的 `dropPCMUntilNextSpeech` |
| `Tests/FluentWorkCoreTests/Architecture/SpeechSessionMiddlewareTests.swift` | 翻转钉住旧契约的测试，补轮次间隙与首次开口前两条 |

`endSpeech()` 与 `abort()` 现在对 PCM 效果相同，但保留为两个入口：调用点用它表达意图（正常收轮 vs 超时放弃），且 `isOpen` 仍承担"迟到的 `speechEnded` 不得发 `user.speech.end`"这条判断。这条不变量没有变。

自动 VAD 模式下的时序：`.speechStarted` 由能量阈值触发，门闩在那一刻打开。阈值以下的前导帧不再上行——这与供应商侧端点检测的触发点基本重合，且 `voiceVadAuto` 非默认路径。

## 4. 为什么不折进已有路径

- **不改成"abort 与 endSpeech 共用一套"**：两者本来就共用一套，问题正是共用的那套把 `endSpeech` 当成了"继续发"。修的是判据，不是入口数量。
- **不在网关上丢**：网关只知道 `user.speech.start/end`，而音频循环是客户端独立的 `.task`；把门闩留在客户端，才不会重演 `docs/20` 里"门闩与相位不一致"的 80+ WARN 级联。网关侧是否也加一道防线另开票。
- **不加 pre-roll 环形缓冲**：自动 VAD 的前导损失在 20–40ms 量级，加缓冲的复杂度换不来可感知收益；若将来自动 VAD 转正再评估。

## 5. 影响面

- **状态**：无相位变化，`SpeechSessionMachine` 未改。
- **协议**：不改任何 WSS 帧。`user.speech.start` / `user.speech.end` 的语义与出站时机不变。
- **音频**：轮次之外的麦克风音频不再出设备。上行带宽下降；供应商缓冲不再跨轮累积。
- **发布**：本机不可见差异——它只在供应商把 commit 窗口内的音频全部转录时才显形（DevEcho 不做转录，所以 Phase 1 测不出来）。
- **风险**：供应商侧若依赖"轮次之间的持续音频"维持双工会话上下文，行为会变。当前靠 `sendSilence` 与网关 60s keepalive probe 保活，见 `docs/24` §6。

## 6. 门禁

```bash
swift test                      # 406/406
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

定向：

```bash
swift test --filter "speechCaptureGate|recordingTimedOut|clientTurnAbort|TurnAbort"
# 16 tests in 2 suites passed
```

## 7. 本票不做

- 网关侧对 `user.speech.start/end` 之外的二进制帧加丢弃（防御性，另开票）
- 自动 VAD 的前导 pre-roll
- `client.turn.abort` 之后 Volc 缓冲的清空（上游无 API，已由重建 duplex 覆盖）
