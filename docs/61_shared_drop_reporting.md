# 判定与上报放进同一个类型

**日期**：2026-09-11
**状态**：**P1-22 的后半（丢弃上报）已做。前半（真实 socket 测试）见 §6 —— 未做。**
**对应**：meta `77_` **P1-22**

## 1. 为什么

P1-22 记了两件事：

1. **没有任何测试构造过真实 socket** —— 连接建立、接收循环生命周期、取消/重连/析构、真实网络错误形态
2. **`InMemorySocketTransport` 共享了丢弃「判定」，但没有共享丢弃「上报」**

本票做的是**第 2 条**，因为台账自己点出了它的代价：

> 而"**丢弃是否可观测**"正是排查时**首先要看的**。

## 2. 缺陷的形状

两个传输各写了一遍门禁接线，而写得**不一样**：

| | 生产传输 | 测试替身 |
|---|---|---|
| `observe` / `shouldDeliver` | ✅ | ✅ |
| `recordDrop`（开启一条丢弃记录） | ✅ | ❌ |
| `closeRun`（以损失大小收尾） | ✅ | ❌ |

**合起来的效果**：生产路径每丢一帧都会发一条 `audioFrameDropped` 诊断，
而**测试替身默默丢弃**。于是：

- 用替身驱动一条路径，**看不见任何丢弃** —— 哪怕生产在同样的输入下会报
- 更糟的是，**替身与生产的可观测行为不同**这件事本身没有测试守着，
  因为替身正是测试用来观察的东西

这与 `77_` P1-18 / P1-19 同族：**单看每一处都像对的**。

## 3. 修法：让"决定丢"与"说丢了"无法分开

新增 `BargeInAudioGate` —— 门禁 **与** 它的丢弃记录**合成一个类型**：

```swift
public mutating func accept(_ sequence: UInt32) -> (deliver: Bool, diagnostic: SocketTransportDiagnostic?)
```

**一次调用同时给出判定与要发的诊断**（丢帧开启一条记录，投递关闭一条）。
所以调用方**拿得到判定就拿得到上报**，没有"只取一半"的写法。

两个传输都改成走它。生产传输那两段私有 helper（`recordDroppedAudioFrame` /
`closeDroppedAudioRunIfNeeded`）因此删掉了 —— 逻辑现在只有一份。

**顺带保住了 P1-7 的顺序**：`clearInterrupt()` 内部**先收尾记录再清水位线**
（先清会把"丢过东西"的唯一证据擦掉）。这个顺序现在由类型保证，而不是由调用点记得。

## 4. 测试

`inMemoryTransportReportsTheDropsItMakes`：打断 → 丢一帧 → 投递一帧，
断言替身记录下**两条**诊断（开启 + 收尾），与生产路径逐字相同。

### 红验证

把替身改回默默丢弃：

```
✘ Test inMemoryTransportReportsTheDropsItMakes() recorded an issue at
  SocketTransportTests.swift:575:5: Expectation failed: (reported → []) == [1, 1]
↳ the double made a drop it never reported: []
```

### 门禁

```bash
swift test          # 466 tests passed  (465 + 1)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

**重构本身没有回归**：两个传输改走同一个类型之后，466 条全绿。

## 5. 另一个坑：替身没有 `deinit`，流永不结束

第一版测试想**排空事件流**来断言诊断，结果**挂满 600 秒**：
`InMemorySocketTransport` 没有会在 `deinit` 里 `finish()` 的东西，
所以 `for await` 永远等下去。

改成让替身**记录**它发出的诊断（`emittedDiagnostics`），与它已有的
`connectCalls` / `sentControlFrames` / `interruptMarks` 同一种风格。

> 这与 P1-7 那次挂起是**同一类**：**测试脚手架的问题，表现成"改动引入了死锁"。**
> 两次都记在这里，以免第三次再误诊。

（中途还撞上一次 `swift test` 因被杀死的后台任务留下 `swift-test` 进程而**持锁等待** ——
`pkill` 掉即恢复。这不是代码问题，但会让下一个人以为是构建坏了。）

## 6. 未做：P1-22 的前半 —— 真实 socket

**这一半没做，且它不是小活。** 台账原文：

> 连接**建立**（含握手时序）、接收循环的**生命周期**、取消/重连/析构、真实网络错误形态
> —— 全部未覆盖，只可能在真机第一次暴露。

**已经有的**（本会话陆续开的）：

- `SocketMessageSource`（P1-12）—— 让接收循环可以用**脚本化消息**驱动
- `InterleavingMessageSource`（P1-7）—— 让脚本能在**帧之间**执行副作用
- 两者合起来覆盖了：帧处理、循环退出、丢弃与上报、打断与水位线

**仍然没有的**：真实 `URLSessionWebSocketTask` 的行为 —— 握手时序、真实网络错误形态
（`NSPOSIXErrorDomain` 之类的具体形状）、取消/析构的真实语义。

**要补它需要先有一个本地 WebSocket 服务器**（后端那边用的是 `httptest` + `coder/websocket`，
iOS 侧没有对应物，也没有依赖可借）。**那是一件独立的基建工作**，不是本票的尾巴 ——
它要么引入一个测试依赖，要么手写一个最小的 WS 服务端。

**登记为未做**，并把"已有什么、缺什么"写清楚，免得下一个人以为这一层已经覆盖了。
