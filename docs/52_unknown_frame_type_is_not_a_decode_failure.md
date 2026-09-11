# 未知帧类型不是解码失败

**日期**：2026-09-11
**状态**：实现与测试已齐。本票不需要真机验证 —— 缺陷是可注入的本地替身复现的，见 §7。
**对应**：meta `77_` **P1-12** · WSS 系列全盘扫描（`meta docs/30_技术方案/81`–`94`）

## 1. 为什么

**前向兼容只做了一半，而且做反了。**

网关对不认识的帧类型是"忽略并计数"（`voicegateway`）。客户端遇到不认识的类型则**抛错 → `handle()` 把它包成 `decodingFailed` → 接收循环发 `.failure` + `.disconnected` 然后 `break`**。

合起来的效果是：**服务端只是加了一个新帧类型，就能让所有老客户端掉线。** 而且两边日志说的不是一回事 —— 服务端记"我发了个它不认识的东西"，客户端记"解码失败"，读日志的人会去查编解码，而真正的原因是版本差。

这与当年 `unsupported_frame` 打死活会话是**同一类事故**，只是搬到了另一端：一边把"我不认识"当成致命，另一边为此付出整条连接。

## 2. 根因：错的那一层是传输层的**反应**，不是解码器的**契约**

`WSControlFrameCodec.decode` 对未知类型抛 `unknownType` —— 这**没有错**。它不能凭空造一个 `WSControlFrame` 出来返回。

错的是调用方对它的解读：

```swift
catch let error as WSControlFrameCodingError {
    throw SocketTransportError.decodingFailed(...)   // ← 未知类型被判成了"帧坏了"
}
```

`unknownType` 是解码器唯一一个**说"信封我看懂了，只是这个名字我不认识"**的信号；其余（缺必填字段、类型不符、JSON 本身坏）才是真的违约。原来的代码把两者合并成同一个 `decodingFailed`，于是循环无法区分"服务器比我们新"和"线坏了"。

## 3. 方案：只改反应，不动契约

在 `URLSessionSocketTransport.handle(message:)` 里**只对 `unknownType` 提前返回**：

```swift
if case let .unknownType(type) = error {
    emit(.diagnostic(.unsupportedControlFrame(type: type, sizeBytes: data.count)))
    return
}
throw SocketTransportError.decodingFailed(...)   // 其余照旧致命
```

**解码器的契约一个字没改** —— 它仍然抛 `unknownType`。所以两条钉住旧契约的测试（`controlFrameCodecRejectsUnknownType`、`AITTSFramesTests` 里那条 `ai.tts.audio`）**不需要动，也不应该动**：它们锁的是解码器的行为，而解码器的行为本来就是对的。

这正是本票可以做到"零既有测试改动"的原因：**改的是解读错误的那一层。**

## 4. 跳过必须留痕

`SocketTransportDiagnostic` 新增：

```swift
case unsupportedControlFrame(type: String, sizeBytes: Int)
```

中间件把它转成 tracker 事件 `transport_control_frame_ignored`（带 `type` 与 `size_bytes`）。

理由与 `AudioDropReport`（`docs/46`）同源，而且是本仓反复踩过的那个坑：**静默的丢弃比丢弃更贵**。"服务端在发一个我们忽略的东西"和"服务端什么都没发"，在没有这条记录时**完全无法区分** —— 而前者正是"新功能上线了但看起来毫无作用"的第一现场。`type` 是那个数据点：它点出我们落后在哪一项上。

## 5. 边界：什么仍然致命

跳过不能变成"什么都跳过"。**信封坏掉的帧是真正的契约违约，仍然必须结束循环** —— 否则"对输入宽容"会安静地删掉"线是坏的"这个唯一的信号。

分界就是 `unknownType` 这一个 case：它是**唯一**一个"其余部分都解出来了"的错误。

## 6. 为测试加的缝：`SocketMessageSource`

接收循环此前**无法在测试里驱动** —— 它直接调 `URLSessionWebSocketTask.receive()`，而全仓没有任何测试构造过真实 socket（这正是 `77_` **P1-22** 记的结构性空白）。

新增一个小协议：

```swift
public protocol SocketMessageSource: Sendable {
    func receive() async throws -> URLSessionWebSocketTask.Message
}
extension URLSessionWebSocketTask: SocketMessageSource {}
```

`receiveLoop` 的签名从 `URLSessionWebSocketTask` 改成 `any SocketMessageSource`，并**由 `private` 改为 internal**。

**为什么不通过既有的 `SocketTransportProtocol` 测**：它观察不到循环的死亡 —— **循环已经死掉的传输层照样能回 `send`**，唯一的 outward 迹象是一个测试得去抢的事件。脚本化的 source 把这件事变成一个事实，而不是一次竞态。

这遵循本仓已有的先例：`makeEventStream()` 也是 internal，注释写着"Extracted so its buffering policy is directly testable"。

**这条缝本身不改变任何行为** —— 先只加缝、跑测试确认仍红，再加修复（见 §7 的红验证顺序）。

## 7. 门禁与红验证

```bash
swift test          # 450 tests passed  (447 + 3 新增)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

### 修复前的实际失败输出（不是转述）

只加了缝、还没改 `handle()` 时：

```
✘ Test receiveLoopSurvivesAnUnknownControlFrameType() recorded an issue at
  SocketTransportTests.swift:272:5: Expectation failed: (events →
  [SocketTransportEvent.failure(SocketTransportError.decodingFailed(
     "control frame decode failed: unknown type \"ai.something.new\" (bytes=39)")),
   SocketTransportEvent.stateChanged(SocketConnectionState.disconnected)])
  .contains(.control(.ping(ts: 7)) → …)
```

**事件列表里只有 `failure` 和 `disconnected`** —— 脚本里排在未知帧后面的那个 `ping` **从未被投递**。这就是缺陷本身：循环在遇到未知类型的那一帧就死了。

### 两次红验证（红的都是预料的那条）

| 破坏 | 结果 |
|---|---|
| 把 `if case let .unknownType(type) = error` 加上 `, type.isEmpty`（等于撤销修复） | `receiveLoopSurvivesAnUnknownControlFrameType` 与 `receiveLoopReportsTheIgnoredFrameType` 红；**`receiveLoopStillDiesOnAMalformedControlFrame` 保持绿** |
| 把兜底 `catch` 的 `throw` 改成 `return`（等于**过度**跳过，模拟偷懒的修法） | **只有** `receiveLoopStillDiesOnAMalformedControlFrame` 红，另两条保持绿 |

第二次破坏是关键的：它证明边界守卫**真的咬得住**，而不是一条跟着实现一起绿的摆设。没有它，一个 `catch { return }` 的偷懒修法会让第 1、3 条测试全绿通过。

**注意 `receiveLoopStillDiesOnAMalformedControlFrame` 在修复前就是绿的** —— 它是一条**不变量守卫**，不是本缺陷的复现（畸形帧本来就致命，本票没有改变这一点）。它的价值在第二次破坏里兑现。

## 8. 影响面

| 维度 | 影响 |
|---|---|
| **协议 / 线格式** | **无改动**。不动帧格式、不动解码器、不动 `WSControlFrame`。本票是纯客户端行为变更 |
| **状态机** | 无改动。恢复的是"该到的事件能到"，不是新相位或新转移 |
| **音频** | 无改动 |
| **发布行为** | **它是发布安全的改动**：老客户端在服务端加帧类型时不再掉线。反过来说，这也是为什么它值得在"加新帧类型"之前落地 |
| **可观测性** | 新增 tracker 事件 `transport_control_frame_ignored` |

## 9. 未做

- **接收循环的其余空白**（`77_` **P1-22**）：连接**建立**（含握手时序）、取消 / 重连 / 析构、真实网络错误形态仍未覆盖。本票只开了"驱动一帧流"这一条缝，没有动连接生命周期。
- **`WSControlFrame` 解码的其余宽容度**：本票只处理"未知 `type`"。**既有类型新增可选字段**的情况本来就由 `decodeIfPresent` 覆盖；**新增必填字段**仍会致命 —— 但 v1 已冻结，且冻结契约的立场是不给既有类型加必填字段，所以不另开路径。
- **服务端那一半**：网关已在忽略并计数，未核对计数是否进入了任何可读的地方。
