# 消费 `server_ts_ms`：字段本身不是延迟，缺的是 offset

**日期**：2026-09-11
**状态**：实现与测试已齐。**未真机验证**，见 §8。
**对应**：meta `78_` §二 **第 1 步** · `77_` **P1-5**

## 1. 为什么

`78_` 把 P1-5 排在第一，理由是它**从可观测性升级成了验收前提**：音频流式（P1-2 音频半边）的全部目的是"让 AI 更早开口"，而这个改善**目前无法量化，只能靠听感**。一个无法度量的改善不是一个可验收的改善。

## 2. 第一个发现：`server_ts_ms` 单独解出来没有用

字段一直是后端在发（`provider_volc_duplex.go` 的 `s.unixMilli()`），iOS 也确实没解。但解出来只是一个**服务端墙钟数字** —— 手机时钟和服务端时钟之间没有任何关系，不建立 offset 就减不出延迟。

后端注释自己写着这个前提（`voiceproto/frames.go`）：

> Clock offset is estimated from ping RTT, not from assuming NTP on the phone.

这不是遗漏，是设计内的。所以 P1-5 的名字叫"消费 `server_ts_ms`"，实际工作量在**建立 offset** 上。

## 3. 第二个发现：offset 的入口存在，但 iOS 走的是另一条分支

`handler.go` 对 `ping` 的应答：

```go
ts := ping.TS
if ts == 0 {
    ts = h.now().UnixMilli()      // ← 只有这条路会带上服务端时钟
}
return writeJSON(ctx, conn, voiceproto.Pong{Type: voiceproto.TypePong, TS: ts})
```

而 iOS 的心跳（`DefaultSpeechSessionClient`）每次都发自己的墙上时钟 → 服务端**原样回显** → **服务端时钟从不过线**。

而 `.pong` 在 iOS 侧此前只有一个 DEBUG 的 typeTag 用到，功能上无人消费 —— 也就是说这条分支走错了两年也没人发现。

**顺带纠正一句注释**：`frames.go` 说"从 ping RTT 估 offset"，但 **RTT 单独给不出 offset**，它只给出不确定度（RTT/2）。要有 offset，服务端必须把自己的时钟发过来。入口在协议里有（`ts == 0` 分支），只是没人走。

## 4. 方案：走 `ts: 0`，不动协议

两条路：

| | 做法 | 代价 |
|---|---|---|
| **a（采用）** | iOS 发 `ping(ts: 0)`，复用后端已有分支 | **零后端改动**。但重载了 `ts` 的含义 |
| b | 给 `Pong` 加 `server_ts_ms` 字段 | 语义干净，但**动协议** —— 撞 `51` §8.1 冻结期白名单的"禁止改 v1" |

选 a。"发 0"从"我没有时间戳"变成"请给我你的时钟"，这个重载**写进了 `ClockProbe` 的文档注释和测试**，否则下一个人会当成 bug 修掉。

### 最需要防的失败模式

一条被回显的 ping 不会**明显**报错：它产生一个约为 `-roundTrip/2` 的 offset，读起来像"几毫秒的正常偏差"，而不像失败。

所以归一化**不放在调用方**，而是放在传输层唯一一处（`ClockProbe.outgoing`）。让这个错误**无法表达**，比让每个调用方记得更重要。

估算器里那个 `serverMs > 0` 守卫只挡得住**最露骨的那种回显**（网关把我们的 0 原样送回）。它挡不住回显真实时间戳的那种 —— 注释里写明了这一点，免得下一个人以为守卫够了。

## 5. 实现：谁owns什么

| 文件 | 职责 |
|---|---|
| `FluentWorkNetworking/Socket/ClockOffset.swift` | `ClockOffset`（值）、`ClockProbe`（线上约定）、`ClockOffsetEstimator`（累积规则）。**纯值类型，无 socket 可测** |
| `URLSessionSocketTransport.swift` | 唯一的往返现场：出站 ping 记 `t0` 并归一化，入站 pong 完成一次采样，改进时发 `.diagnostic(.clockOffsetEstimated)` |
| `SocketTransport.swift` | 新增那个 diagnostic case。走既有 diagnostic 通道，**零 conformer 改动** —— 该通道的注释本来就写着"reducer 层可以忽略" |
| `WSControlFrame.swift` | `aiTextDelta` 补上 `turnID` 与 `serverTsMs`（后端一直在发，iOS 一直在丢） |
| `SpeechSessionTimingsRecorder.swift` | 持有 offset；新增 `markFirstResponse`，发射 `timing_first_response` |
| `SpeechSessionMiddleware.swift` | 两处接线：diagnostic → recorder；首帧 → `markFirstResponse` |

**为什么不让 offset 走一条新的事件**：`SocketTransportEvent` 有 15 个文件引用，加 case 要动 `SocketTransportEventMapper` 的穷尽 switch。diagnostic 通道就是为这种事开的。

**为什么估算是纯值类型**：和 `AudioFrameDropPolicy` / `AudioFrameDropGate` 同一个形状 —— **规则住在可测的地方，传输层只决定样本从哪来**。

### 一条规则：留最紧的窗口，不留最新的

真 offset 落在**每一个**采样的区间内，所以区间最小的那个钉得最准。新采样只能靠"更快"取胜，不能靠"更晚"。

## 6. 一个差点写反的符号

`ClockOffset.milliseconds` 是 `server − local`。把服务端时间戳换算到本地钟上要**减**它。

我第一版写成了 `serverMs + milliseconds`。是在**写测试算例时**发现的 —— 因为测试要求把数字算出来，加法当场给出 `1_010_000` 而不是 `1_000_000`。

这个符号错误值得单独记一笔：**加法的产物是一个看起来完全合理的延迟，只是错了 2 倍 skew。** 所以它有一条专门的守卫测试（`clockOffsetPutsAGatewayStampOnTheLocalClock`），红验证时把它改回加法，该测试与那条 split 测试同时变红。

## 7. 顺带：首响其实不需要 offset

**这条改变了 P1-5 的形状，值得单独说。**

首响延迟的两个端点**都在客户端时钟上**：

| 端点 | 位置 |
|---|---|
| 起点：发出 `user.speech.end` | 中间件 |
| 终点：收到第一帧音频 | `timing_ai_first_chunk`（已有） |

两个端点同钟，**相减即可**，不需要 offset，不需要 `server_ts_ms`。缺的只是起点那一行锚。

所以这次一并做了 `markFirstResponse`：它把总延迟报出来（`first_response_ms`），offset 只用来**把总延迟拆成上行 / 服务端 / 下行**。**offset 拿不到时，总数照报，拆分不编造。**

两个刻意的决定：

1. **锚在 `markTurnStarted` 上，不是锚在"上一个 mark"上。** ASR 中继落在两者之间且会被 mark，用 delta 链会安静地从转录时刻开始量 —— 数字仍然像个延迟，但错了一整个 ASR 跳，而那恰好是读者会据此判定"很快"的那一跳。
2. **每条报一次。** 流式回复的每一帧都会宣告自己，只有第一帧是"AI 开始回答"。全报会把"多久开口"变成"多久说完"。

## 8. 门禁与红验证

```bash
swift test          # 447 tests passed
```

**四次红验证，红的都是预料的那条**（按 `78_` §五 的纪律：红的是别的或全绿，说明测错了东西）：

| 破坏 | 结果 |
|---|---|
| `ClockProbe.outgoing` 直接透传 | `clockProbeBlanksTheTimestamp…` 红；`clockProbeLeavesEveryOtherFrameAlone` **保持绿**（它不测 ping 改写） |
| `serverToLocalMs` 改回加法 | 两条换算测试 + split 测试红；**`clockOffsetEstimatorRecoversAKnownSkew` 保持绿** —— 估算走 `record()` 里另一个表达式，两组测试互不掩盖 |
| 去掉"每轮一次"的登记 | `firstResponseIsReportedOncePerTurn` 收到 **3** 条；`markTurnStartedReArms…` 保持绿（它测的是重新武装，不是去重） |
| 去掉"留最紧窗口" | `…KeepsTheTightestRoundTripNotTheNewest` 红；`…AdoptsAFasterRoundTrip` 保持绿 |

**未真机验证**：

- 首响 p50/p95 的实际数字（这才是 P1-5 的验收本身）
- offset 的实际量级与抖动 —— 服务端与手机是否真的差到需要修正，目前只有推理
- `server_to_client_ms` 与 `first_response_ms` 是否自洽（差值应为上行耗时）

## 9. 一处被改动的既有行为

`DefaultSpeechSessionClient` 的心跳从"先睡 30s 再发"改成"**先发**再睡"。原因是不改的话，**第一轮**——也就是所有人真正会去看的那一轮——在 30 秒内没有 offset 可用，它的延迟会一直读作"不可测"。

这条改动让 `defaultSpeechSessionClientCreatesSessionAndConnectsSocket` 变红（它断言"只发了 `session.start`"）。该测试改为断言**顺序与形状**而非精确集合：第一个 ping 从独立 Task 发出，断言精确数组会变成竞态。

## 10. 未做

- **`ai.turn.end` 不带 `server_ts_ms`**，只有 `ai.text.delta` 带。所以目前只有文本首帧能拆，音频首帧只有总数。
- **`timing_ai_first_chunk` 量的是传输层收到，不是开始播放。** 对"AI 更早开口"这个用户可感的指标，播放起点更准 —— 这是一个可选精化。
- 传输层现在有**两条独立保活**（协议级 `sendPing` 30s 与 app 级 `.ping` 30s），职责不同但都不可删：前者是 iOS 侧唯一的存活探测，后者是后端 2 分钟读空闲超时唯一的输入。**这个分工没有写在任何地方**，见 §11。

## 11. 记一条：两条保活都不能删

`coder/websocket` 的 `Read` 不返回控制帧（`read.go` 把 `opPing/opPong/opClose` 交给 `handleControl` 内部消化），所以**协议级 ping 到不了 `handler.go` 的 `conn.Read`，不解后端的空闲定时器**；只有 app 级 JSON ping 会。

删任何一条都出事：删协议级 → 失去唯一存活探测；删 app 级 → 失去唯一喂后端超时的输入（后端会开始按 2 分钟空闲回收会话，而今天是**永远不会**回收的，因为心跳一直在喂）。

后者本身是个产品问题：心跳把后端一个明确的回收机制**完全屏蔽**了。用户放下手机，会话会一直挂着。
