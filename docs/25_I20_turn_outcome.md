# T-I20-2 TurnOutcome 对齐与状态机上报

**票**：I20 T-I20-2  
**状态**：已落地（iOS）。Backend 仍未接受 `client.turn.abort`；现网联调仍会 `unsupported_frame`。

## 1. 要守住的原理

一轮用户说话只有两种合法收口：

1. **正常结束** → `user.speech.end`，本侧记 `TurnOutcome.ok`，gateway 才可以 `collectTurn`。
2. **开口尚未结束就死掉** → `client.turn.abort`，本侧记 `timeout` / `user_abandoned` / `error`，**不得**再发 `user.speech.end`，也不得把 abort 写成 `ok`。

`ok` 不是 abort 的线值。S→C 的 `ai.turn.end` 仍用 `WSControlFrame.TurnOutcome`（含 `partial`），不要和本枚举合并。

这和 B15 的 70s `turn_timeout` 仍是两条路：B15 发生在 `user.speech.end` 之后、处理中；本票发生在 `.recording` 仍开口时。合同见 `docs/24_voice_turn_timeout_contingency.md`。

## 2. 根因

T-I20-1 把 60s 录音超时做成了 abort，但 `outcome` 在状态机、副作用和 WSS 上都是裸 `String`，schema 还钉死 `const: "timeout"`。

后果：

- 用户在录音中点结束 / 切后台 / 网络断开时，catch-all 只走 `endSession` / `forceClose` / 重连，**开口轮对 gateway 仍是 start 而未 end**。
- 若误用 `user.speech.end` 来收这些路径，gateway 会启动 `collectTurn`，并可能把空转写进 `outcome=ok`（`docs/20` §1.2 缺陷 #1 的同类误标）。
- 后续 I21 需要共享 `TurnOutcome`，不能继续靠字符串约定。

## 3. 方案

Core 增加 `TurnOutcome`：`ok` / `timeout` / `user_abandoned` / `error`。  
Networking 增加独立线类型 `WSControlFrame.ClientTurnAbortOutcome`：只有后三个值。

| 时机 | `lastTurnOutcome` | 线帧 |
|---|---|---|
| `.recording` + VAD/hold 结束 | `.ok` | `user.speech.end`（既有路径，不 abort） |
| `.recording` + 60s `.recordingTimedOut` | `.timeout` | `client.turn.abort` |
| `.recording` + `.endTap` / `.forceClose` | `.userAbandoned` | abort，再 `endSession` / `forceClose` |
| `.recording` + `.failed` / `.networkLost` / `.networkDegraded` | `.error` | abort；lost 离开 recording 并开重连，degraded 进文本降级，failed 结束会话 |

录音专用分支必须写在 `(_, .endTap)` / `(_, .forceClose)` / `(_, .failed)` / `(_, .networkLost)` 这些 catch-all **之前**。

`ok` 在 `DefaultSpeechSessionClient.sendTurnAbort` 里被丢掉，编解码拒绝 `outcome: "ok"`。

Schema `$defs.clientTurnAbort.outcome` 从 `const: "timeout"` 放宽为 `enum: ["timeout", "user_abandoned", "error"]`。真源仍在 `fluentwork-infra`；本仓库改的是镜像。

## 4. 为何不复用已有路径

- 不把 abandon/error 折进 B15 `.failed("turn_timeout")`：那是处理中 70s，会杀会话。
- 不把 abort 折进 `interrupt`：那是 AI 说话时的 barge-in。
- 不把 Core `TurnOutcome` 与 `WSControlFrame.TurnOutcome` 合成一个类型：后者有 `partial`，方向是 S→C。

## 5. 影响面

- 状态：`SpeechSessionState.lastTurnOutcome`
- 协议：abort `outcome` 变为枚举；`ok` 非法
- 音频：不改采集；abandon/error 仍由既有 middleware 停采集 / 关门闩
- 行为变化：录音中 `networkLost` 会离开 `.recording` 并发 abort（以前只打重连标记、相位不变）

## 6. 测试

- 四种 outcome 的 machine 测试
- abort JSON：`timeout` / `user_abandoned` / `error`；拒绝 `ok`
- schema pin：`enum`，不再 `const`

```bash
swift test --filter "TurnOutcome|clientTurnAbort|recordingTimedOut|endTapFromRecording|failedFromRecording|networkLostFromRecording"
```
