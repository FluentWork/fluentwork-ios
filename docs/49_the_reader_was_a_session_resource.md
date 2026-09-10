# 读连接的人被当成了会话资源

**日期**：2026-09-11
**状态**：代码与测试已齐。门禁见 §6。
**触发**：真机 —— 「点击结束练习，从工作台再次进入 speaking room，会出现 连接中」（F20）
**关联**：`docs/48`（`.connecting` 无超时）· meta `77_` F21

## 1. 守住的不变量

**资源的生命周期要配得上它管的东西。** 读一条**连接**的循环，不该由某个**会话**的结束来决定生死。

## 2. 根因：一条进程级流，被每会话建一次、每会话取消一次

```
URLSessionSocketTransport.events   ← AsyncStream，随传输层活整个进程（.singleton）
    ↓
speechClient.transportEvents()     ← 每次调用返回同一条流
    ↓
.task(id: transportEvents)         ← 消费者：.createSession 建，.endSession 取消
```

三处都错：

1. **`AsyncStream` 是单消费者序列。** 一条流、多个短命迭代器 —— 垂死的那个会和新的一起抢元素。
2. **取消落在错误的时刻会杀掉新消费者。** `.endSession` 发出 `.cancel(id: transportEvents)`；一次紧跟其后的重进会在**这个取消落地之前**启动下一个会话的消费者 —— **取消杀掉的是新的那个**。
3. **循环静默退出。** `for await` 遇到取消**正常结束**，没有错误、没有事件。

## 3. 真机证据

```
（服务端）03:34:51.550  practice session created
          03:34:51.573  voice.handshake.done / voice session ready
          03:34:51.574  session.start accepted      ← 客户端的 session.start 到了

（客户端）timing_transport_consumer_start     total_ms 0.360
          timing_transport_consumer_exit      total_ms 0.519   ← 159ms 后退出
          connecting → failed                 total_ms 10596   ← 看门狗收场
```

**服务端 24 毫秒就绪，客户端在写、但没人读。** Socket 是好的 —— 这一点值得单独确认，因为"是不是 WebSocket 断了"是最自然的怀疑，而答案是**没断**。

## 4. 复现：不是"看起来不对"，是**挂住**

新测试驱动 **开始 → 结束 → 重进**。在改动前的中间件上：

```
✘ transportReaderIsBuiltOncePerStoreNotOncePerSession
  Caught error: TimeoutError()      ← 第二个会话的 waitForPhase(.aiSpeaking)
```

**第二个会话根本到不了 `.aiSpeaking`** —— 与真机同一症状，确定性复现。

测试里之所以确定而真机上是间歇的：测试中 `.endSession` 的取消和重进之间只隔几个微秒，**必然**落入那个竞态窗口；真机上这个窗口是几百毫秒，用户手动重进，所以只是**有时**失败。

改动后：绿灯，并额外断言 `transportEventsRequestCount == 1`（读者只建一次）。

## 5. 官方做法怎么说

查过了 —— **传输层那一层本来就是标准做法**：

- `URLSessionWebSocketTask.receive()` **一次只收一条消息**，必须反复调用。长驻接收循环（legacy 的 completion-handler 递归 / 现代的 `while !Task.isCancelled`）是**唯一**的用法，不是选择。
- 官方推荐把它包成 `AsyncThrowingStream` 供调用方 `for await`。

**所以问题不在这两层，而在再往上一层**：流的**消费者**被绑成了会话资源。

顺带记下研究里提到的两条我们**尚未**处理的实践（见 meta `77_` F21 备注）：

- `maximumMessageSize` 有默认上限，大消息会在接收回调里以误导性的网络错误失败
- 断线**没有内置重连**：`receive()` 一旦返回错误，task 就结束了，必须重建 task

## 6. 方案

把读者提到**store 级、只建一次、永不取消**：

```swift
// 绑在"第一次要会话"上，而不是绑在 .appLaunched 事件上
var pumpEffects: [Effect<AppAction>] = []
if case .speakingRoom(.session(.sessionStartTap)) = action, transportPumpStarted.take() {
    pumpEffects.append(transportEventPump(...))
}
```

**为什么不用 `.lifecycle(.appLaunched)` 触发** —— 第一版就是这么写的，测试立刻指出它把"传输层可读"绑在了一个**无关事件**上：谁忘了派发，房间就静默卡住，**正是这次要消除的失败形状**。绑在"第一次要会话"上则自洽：要用连接的人，自己把读者带起来。

`.endSession` / `.forceClose` 里的 `.cancel(id: transportEvents)` 删除 —— **取消一个不属于这个会话的资源，本身就是错的**。

## 7. 门禁

```bash
swift test                      # 428/428 ×3
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' build
# ** BUILD SUCCEEDED **
```

| 测试 | 守住的不变量 | 改动前 |
|---|---|---|
| `transportReaderIsBuiltOncePerStoreNotOncePerSession` | 读者属于连接，一个 store 只建一次；重进必须还能连上 | `Caught error: TimeoutError()`（第二个会话到不了 `.aiSpeaking`） |

## 8. 音频引擎那条消费者：同一形状，第二半（本票已做）

第一版把这条留在"不做"里，理由是"它的状态是会话级的"。**真机立刻证明这个理由不成立** —— 重进修好之后（45ms 连上），点「开始说话」**没有任何反应**：

```
transport_consumer_saw_connected   total_ms 45.219
connecting → aiSpeaking            total_ms 45.753    ← 传输泵修好了
session.ready → ai.turn.end → waitingUser
   ⋯⋯ 30 秒什么都没有 ⋯⋯                              ← 点「开始说话」之后
```

点「开始说话」直接调 `audioEngine.beginManualSpeech()`，引擎把 `.speechStarted` 发进流里 —— **但没人读**。机器停在 `waitingUser`，界面看起来就是"按钮坏了"。

**"状态是会话级的"这个理由错在哪**：`pcmBuffer` / `isCapturingSpeech` 确实是会话级**语义**，但它们**恰好是安全的**跨会话残留 —— `.speechStarted` 里先 `pcmBuffer.removeAll()` 再 `speechCaptureGate.beginSpeech()`，顺序保证上一会话的 PCM 到不了线路。**语义是会话级的，不代表持有它的那个循环必须是会话级的。**

修法与传输泵完全一致：`audioEventPump`，与 `transportEventPump` 一起在"第一次要会话"时启动，store 级、永不取消。

| 测试 | 守住的不变量 | 改动前 |
|---|---|---|
| `audioReaderSurvivesSessionEnd` | 重进之后点「开始说话」必须能进入 `.recording` | `Caught error: TimeoutError()` |

## 9. 本票不做
- **不加重连**：`receive()` 出错即终结，需要重建 task。目前由 `connect()` 重建，未验证重连路径。
- **不设 `maximumMessageSize`**：我们的帧是 3.2 KB，未触发；研究提示这是常见坑，已记录。
