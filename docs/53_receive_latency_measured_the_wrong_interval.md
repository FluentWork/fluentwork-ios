# `receiveLatency` 量错了区间 —— 三处，同一个标记

**日期**：2026-09-11
**状态**：实现与测试已齐。不需要真机验证。
**对应**：meta `77_` **P1-13**（第 1 处）· 第 2、3 处为本次新发现

## 1. 为什么

`timing_socket_receive` 这个标记的作用，是让"一帧从 `receive()` 返回，到被处理完"的耗时出现在日志里，**按帧类型可分**。它此前三处都没做到：

| # | 缺陷 | 来源 |
|---|---|---|
| 1 | 起点采样在 `await` **之前** —— 量到的是 socket 干等下一帧 | `77_` P1-13 |
| 2 | 终点采样在 `handle()` **之前** —— 解码与派发的开销完全没算进去 | 本次发现 |
| 3 | `frame_type` 取的是 JSON 的**键**，不是值 —— 每一帧都记成 `"type"` | 本次发现 |

**三处共同点：数字一直看着合理，所以没有一处会自己暴露。**

第 1 处最典型：一次爆发在其边界给出一个大样本、爆发内部全是近零 —— 这条曲线**看起来正是"突发流量"该有的样子**。而它实际描述的是"socket 空闲了多久"，与处理开销无关。

第 3 处则更安静：`frame_type` 恒为 `"type"`，而**音频路径是对的**（`audio_binary`）。一半对，是最难被怀疑的一种坏法 —— 读日志的人看到列里有值、有区分度（`audio_binary` vs `type`），只会以为控制帧恰好都叫这个名字。

## 2. 三处的成因各不相同

**第 1、2 处是同一个取样位置写错。** 原来的循环：

```swift
let receivedAt = ContinuousClock.now      // ← 在 await 之前
let message = try await task.receive()
let decodedAt = ContinuousClock.now       // ← 在 handle 之前
let receiveElapsedMs = Self.elapsedMs(from: receivedAt, to: decodedAt)
try handle(message: message)
```

两个采样点，**一个偏早、一个偏早**，把区间的两端都往外挪了：起点挪到了"等"里面，终点挪到了"做"外面。

而 `logReceiveLatency` 自己的文档注释写的是另一回事：

> the wall-clock time between `URLSessionWebSocketTask.receive()` returning and `handle()` finishing

**注释描述的是修好之后的行为。** 这条差异没有测试去问，所以它就一直是注释里的那个样子。

**第 3 处是一段手写的 JSON 扫描。** 它取"第一个引号到第二个引号之间"：

```swift
let firstQuote = text.firstIndex(of: "\"") ?? text.startIndex
let afterQuote = text.index(after: firstQuote)
let endQuote = text[afterQuote...].firstIndex(of: "\"") ?? text.endIndex
let type = String(text[afterQuote..<endQuote])
```

对 `{"type":"ping",...}` 来说，前两个引号夹的是**键** `type`。红验证里能看到它在别的输入上退化得多彻底：`{"ts":7}` 得到 `"ts"`，字符串 `not json` 得到 `"ot json"`。

## 3. 修法

**第 1、2 处**：两个采样点都收紧到"工作"的两端。

```swift
let message = try await source.receive()
let receivedAt = ContinuousClock.now
try handle(message: message)
let handledAt = ContinuousClock.now
```

**第 3 处**：抽成纯函数 `URLSessionSocketTransport.controlFrameType(in:)`，读 `"type"` 之后的**值**，读不到返回 `nil`（调用方记为 `"unknown"`，不编造名字）。

**为什么继续从原始 JSON 读，而不是从已解码的帧读**：未知类型的帧**会被跳过、永远不会变成一个 `WSControlFrame`** —— 而那恰恰是最该在日志里看到类型的一批帧。从解码结果读会正好漏掉它们。

## 4. 门禁与红验证

```bash
swift test          # 453 tests passed  (450 + 3 新增)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

### 修复前的实际失败输出（不是转述）

```
✘ Test receiveLatencyDoesNotMeasureTheWaitForTheNextFrame() recorded an issue at
  SocketTransportTests.swift:301:5: Expectation failed:
  ((sample?.elapsedMs ?? .infinity) → 128.211459) < (60 → 60.0)

✘ Test receiveLatencyIncludesTheCostOfHandlingTheFrame() recorded an issue at
  SocketTransportTests.swift:328:5: Expectation failed:
  ((sample?.elapsedMs ?? 0) → 0.029167) > 0.5
```

第一条：一个空闲了 **120ms** 的连接，样本读出 **128ms** —— 量到的几乎全是等待。
第二条：一个 **8 MiB** 的音频帧（`WSAudioFrameCodec.decode` 里有 `Data(payload)` 的真实拷贝），样本读出 **0.029ms** —— `handle()` 的拷贝成本不在区间里。

### 第 3 处是在写测试时被抓出来的

给第 1 条写断言时，`frameType` 取回来的是 `"type"`：

```
✘ Test receiveLatencyDoesNotMeasureTheWaitForTheNextFrame() recorded an issue at
  SocketTransportTests.swift:296:5: Expectation failed:
  (sample?.frameType → "type") == "ping"
```

**这是"先写测试"直接兑现的一次收益**：单看实现，那段扫描读起来像是"取第一个引号里的东西"，只有把期望值写下来（`"ping"`）才当场显形。

### 三次红验证（红的都是预料的那条，且互相不掩盖）

| 破坏 | 结果 |
|---|---|
| **A** 起点挪回 `await` 之前 | 空闲测试红（**128.39ms**）；处理测试**保持绿**（它只要求区间包含 `handle()`，而那一点没被破坏）；`frame_type` 绿 |
| **B** 终点挪回 `handle()` 之前 | 处理测试红（**4.2e-05ms**）；空闲测试**保持绿** —— 起点位置未动 |
| **C** 换回旧的"取前两个引号"扫描 | 两条 `frame_type` 测试同时红，且输出正是旧代码的垃圾值：`"type"`、`"ts"`、`"ot json"` |

A 与 B 的**互补保持绿**是关键：它们证明两条测试各自守住了区间的一端，而不是一条测试掩盖了另一条。

## 5. 影响面

| 维度 | 影响 |
|---|---|
| **协议 / 线格式** | 无改动 |
| **状态机 / 音频** | 无改动 |
| **发布行为** | 无行为变更 —— 改的是**测量**与**日志内容**，不是数据通路。传输层收发的东西一个字节没变 |
| **可观测性** | `timing_socket_receive` 的 `elapsed_ms` 与 `frame_type` 两列从此可信。**此前所有基于该标记的读数都不可用**，包括用它来评估"解码是不是瓶颈"的任何结论 |

**最后一条要单独说**：这不是"数字略有偏差"，而是**两列都指错了对象**。任何引用过这两个数字的判断（例如"音频路径的解码开销占主导"——那是 `logReceiveLatency` 注释里写着的猜测）都需要重新取值。

## 6. 未做

- **`elapsedMs` 与 `server_ts_ms` 的关系**：本票只修本地区间。首响的上行/服务端/下行拆分依赖 `ClockOffset`（`docs/51`），未动。
- **爆发内部的样本仍然会很小** —— 那是**正确的**：处理一帧本来就快。修好之后"爆发边界大、内部小"这个形状**依然存在**，但它的含义变了：从"空闲了多久"变成"这一帧处理了多久"。**没有任何断言能替代人对这个形状的重新解读**，所以记在这里。
- **`SocketMessageSource` 目前只服务接收循环**（P1-22 的一部分）。连接建立、取消/重连/析构仍未覆盖。
