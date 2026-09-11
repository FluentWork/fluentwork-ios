# 长 TTS 打断：先发 interrupt，再发 user.speech.start

**日期**：2026-09-12
**状态**：实现与测试已齐。
**对应**：backend `docs/63` / `docs/66`（网关在 collect 中不因 start 清掉 `deliveredText`）

## 1. 守住的不变量

**从 `.aiSpeaking` barge-in 时，WSS 上 `interrupt` 必须出现在 `user.speech.start` 之前。**

反过来会让网关把上一轮已经推给客户端的 `deliveredText` 清掉，interrupt 日志永远是 `delivered_chars: 0`，转录截断成空操作。

## 2. 根因

`audioEventPump` 在 VAD `speechStarted` 时**先** `sendSpeechBoundary(started: true)`，**再** dispatch `vadSpeechStart`。状态机那一侧才 `fireAndForget` 发 `interrupt`。

泵跑在 reduce 之前，当时看不到「现在是 `.aiSpeaking`」。生产帧序因此是：

```
user.speech.start   ← 网关 resetTurnStreamingState()
interrupt           ← deliveredText 已经是空的
```

## 3. 修法

泵里放一个 `SessionPhaseBox`，每次 reduce 后写入当前相位。`speechStarted` 时若相位是 `.aiSpeaking`，先 `submitTranscript("__interrupt__")`，再发 start。

机器侧原有的 interrupt 仍会再发一次。重复 interrupt 对网关是无害的；缺第一次才是事故。

## 4. 测试

`bargeInFromAISpeakingSendsInterruptBeforeUserSpeechStart`（`SpeechSessionMiddlewareTests.swift`）。

### 修复前的实际失败输出

去掉泵里对 `.aiSpeaking` 的提前 interrupt 之后：

```
✘ Test bargeInFromAISpeakingSendsInterruptBeforeUserSpeechStart()
  interrupt must precede user.speech.start so the gateway does not wipe deliveredText;
  got ["user.speech.start", "interrupt"]
```

（`interruptAt < startAt` 为假。若机器侧的 fireAndForget 还没跑完，`got` 里甚至只有 `user.speech.start`。）

## 5. 门禁

与 `docs/66` 同一次 `swift test` / Host Debug 构建。本票不单独跑全量。

## 6. 明确没做的

- 没有改评价阶段的 barge-in（那条路径只发 `.stopPlayback`，不发 WSS `interrupt`）。
- 没有取消火山侧生成。
