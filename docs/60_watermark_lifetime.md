# 播放门禁的水位线：按轮失效

**日期**：2026-09-11
**状态**：传输层那道水位线已修。**引擎那道是剩下的半边，见 §5。**
**对应**：meta `77_` **P1-7**

## 1. 为什么

`AudioFrameDropGate.interruptMaxSequence` 只由 `connect()` 清除，而 `clearInterrupt()`
**在生产代码里零调用**（只剩定义与测试）。所以在一个会话内，它**从不被清理**。

**它做的事是按轮的，给它的生命周期是按会话的。**

打断发生时，水位线记下"已经发出去的最高序号"，此后所有 `序号 ≤ 水位线` 的帧被丢弃 ——
要丢的是**被用户打断的那一轮**已经在途的音频。而它一直活到下一次 `connect()`。

## 2. 两者什么时候真的分叉

**只在序号回退时。** 而那正是 **F18**：透明重开把序号从 1 重来，而水位线还停在几百 ——
之后每一帧被**静默**丢弃，文字照常返回、音频永久消失、不报错。

**后端已经改成跨重开接力编号了**，所以这条具体路径不会复发。
但**门禁仍然依赖"后端不会让序号回退"这个前提** —— 而它没有任何东西保证这一点，
下一个新重开路径 / 新 provider / 协议改动，会以完全相同的方式复发。

**本票钉住的是门禁，不是后端。**

## 3. 边界用 `ai.turn.end`

理由四条：

1. **它是终局的** —— B15 保证每条退出路径都发
2. **一轮的音频永远在它之前**（音频是流式发的，`ai.turn.end` 收尾）
3. **它带 `turn_id`** —— 将来要按特定轮次清也有依据
4. **它已经到达传输层** —— 传输层自己解码控制帧，**不需要新增任何接线**

第 4 条是关键：这也是为什么本票**没有**去动中间件那条 `submitTranscript("__interrupt__")`
的字符串哨兵。**修的是水位线的生命周期，不是那个接缝。** 顺手改接缝会把一件事做成两件。

## 4. **明确否决**的做法（台账已记，这里再记一次）

「序号看起来变小了就重置水位线」的启发式。它会在**真正的乱序场景**下帮倒忙，
而且会把真 bug 藏起来 —— 门禁逻辑本身没错，错的是它依赖的前提。

## 5. 两道水位线，本次只修了一道

客户端有 **2 道**，都只在会话级重置：

| 门禁 | 位置 | 置位 | 清除 | 本次 |
|---|---|---|---|---|
| `AudioFrameDropGate.interruptMaxSequence` | `URLSessionSocketTransport` | `markInterrupted()` | **只有 `connect()`** | ✅ 已改为按轮 |
| `AudioPlaybackGate.interruptWatermark` | `LiveAudioEngine` | `interruptNow()` | `startCapture()` / `stopCapture()` | ⬜ 未动 |

**为什么只修第一道**：它是**零调用**的那一个（`clearInterrupt()` 有定义没使用者），
也就是台账点名的那一个；而且它自包含 —— 传输层自己就有 `ai.turn.end`。

**第二道的风险更低但形状相同**：它丢的是**播放**时 `序号 ≤ 水位线` 的帧，
而那些帧要走到它面前，得先穿过第一道。第一道修好之后，第二道只在"第一道放行了不该放行的帧"时才有意义。
**要修它需要新加一条 `AudioEngine` 协议方法 + 中间件在轮末调用** —— 那是独立改动，
且要先说清它到底防住了第一道没防住的什么。**未做，已登记。**

## 6. 测试

`theBargeInWatermarkDoesNotOutliveItsTurn`（`SocketTransportTests.swift`）。

用 P1-12 开的那条 `SocketMessageSource` 缝驱动接收循环，并让脚本能在**帧之间**执行副作用
（`InterleavingMessageSource` 的 `.perform` 步）—— 这是把打断放进**音频流中间**的唯一办法。

脚本：音频 1、2 → **打断** → `ai.turn.end` → 音频 1（**序号回退**，F18 的形状）。

判据是 `delivered.filter { $0 == 1 }.count == 2` —— 同一个序号被投递两次，
是"水位线被清掉了"的**签名**，而不是巧合。

### 修复前的实际失败输出

```
✘ Test theBargeInWatermarkDoesNotOutliveItsTurn() recorded an issue at
  SocketTransportTests.swift:538:5: Expectation failed:
  (delivered.filter { $0 == 1 }.count → 1) == 2
↳ the post-turn frame was dropped: watermark outlived its turn
```

### 红验证

去掉 `dropGate.clearInterrupt()` → 红，信息同上。

### 门禁

```bash
swift test          # 465 tests passed  (464 + 1)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

## 7. 写这个测试时踩的两个坑（都值得记）

**一、传输层持在局部 `let` 里 → 测试永久挂起。**

事件流只在传输层 `deinit` 时 `finish()`。我第一版写 `let transport = ...`，
于是 `release()` 之后仍有引用、`deinit` 不执行、`for await` 永远等下去 —— **挂满 600 秒**。

改成 `TransportHolder.make()` 返回"已被 holder 持有、调用方不留引用"的一对。
这条写进了那个工厂方法的文档注释里，因为它**看起来像多余的一层**，但去掉就会复现挂起。

**二、`@Sendable` 闭包不能捕获 `var`。**

那个 `.perform` 步要够到传输层才能打断，而传输层若声明成 `var` 以便释放，就捕获不了。
holder 是 actor，两个问题一次解决。

> 两次都是**测试脚手架**的问题，不是产品代码 —— 但第一次的表现（挂起 600 秒）会被误读成
> "改动引入的死锁"。**记在这里以免下一次误诊。**
