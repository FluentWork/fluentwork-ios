# 两条死路：标记，不接线

**日期**：2026-09-11
**状态**：实现与测试已齐。**标记 + 钉住**，未删除任何东西。
**对应**：meta `77_` **P1-15** · 形状定义见 meta `docs/30_技术方案/88` §⑧

## 1. 为什么是"标记"而不是"接线"

`88_` §⑧ 给了这个形状一个名字：**有消费、有测试、没有生产者**。

> 对每一个状态或分支，问一句 —— **谁生产进入它的那个事件？**
> 如果答案只在测试里，那它不是一条路径，是一个装饰。

它的代价不是崩溃，是**认知**：任何照着代码读系统的人，会**多知道一件不存在的事**。

而本次核实改变了处置方式 —— **其中一条根本不是"忘了接"，是接不了**：

| | 缺什么 | 能否由 iOS 单边补上 |
|---|---|---|
| ① `processingReview` | 进入它的事件只有测试在派发 | **不能** —— 信号只能来自网关，而网关不发 `review` |
| ② "重连成功" | 没有任何东西重开 socket | **不能** —— 网关根本无法恢复会话（§3） |

两条都补不上，所以**接线不是选项**。剩下的选择是"删掉"或"标记"。**选了标记**，理由在 §5。

## 2. ① `processingReview`：生产者只能在线的另一端

进入它的唯一入口是 `.processingStageReached(.review)`，而**全仓生产代码一处都没有派发过它**。

要补，信号必须来自网关 —— 而网关 `stage` 的全部词汇只有
`orchestration` / `asr` / `tts` / `scheduler` / `transport`，**没有 `review`**。
这与 `77_` **P1-20** 记的"阶段标签只兑现 3/13"是同一个缺口的两面。

**它是"没有跑"，不是"跑了但看不见"。** 这一点值得写清楚，因为两者在日志里的样子一样，而修法完全不同。

> 顺带：`P1-3` 相位收敛刚把 `processingReview` 从**相位**降成**阶段**。
> 收敛没有制造这个问题（问题一直在），但把"这条路是活的"这个暗示从相位表搬到了阶段表 —— 所以标注跟着搬到这里。

## 3. ② 重连：不是"忘了接"，是接不了

### 3.1 先纠正一个更基本的误解：那个 3 秒窗口**不尝试**

```swift
case .startReconnectWindow:
    return .task(id: SpeechSessionTaskID.reconnectWindow) {
        try? await Task.sleep(for: .seconds(3))          // ← 只是睡
        ...
        await dispatchBox.dispatch(.speakingRoom(.session(.reconnectTimedOut)))
    }
```

它**从不重开 socket**。所以"3 秒窗口内自动重连"这句话里，只有"3 秒"是真的。

**每一次网络丢失都必然落到文本降级**，没有例外。

### 3.2 死掉的不是一个事件，是七个 artifact

| # | 位置 | 状态 |
|---|---|---|
| 1 | `SpeechSessionEvent.reconnectSucceeded` | 无生产者 |
| 2 | 状态机 `(_, .socketReady) where isReconnecting` | 分支完整、正确，但**进不去**（没有 `.connected` 会在 `isReconnecting` 时到达） |
| 3 | `Configuration.reconnectWindow` | **声明了，从不读**。实际生效的窗口硬编码在中间件；两个字面量数值相同但**没有连在一起** |
| 4 | `SocketConnectionState.reconnecting` | **从未被发出过** |
| 5 | 中间件的 3s 窗口 | 名字与周围状态（`reconnecting`、`reconnectSucceeded`）都读作"重连进行中" |
| 6 | 状态机 `completeReconnect` | 只有上面那个进不去的分支调用 |
| 7 | `reconnectWindow` 的 `CancellationID` | 语义是"窗口"，实际是"降级延时" |

这正是 `88_` §⑧ 说的"比死字段更难发现"：**每一处单看都在暗示这条路是活的。**

### 3.3 为什么接线不是 iOS 能做的 —— 后端核实

要让"携 `session_id` 恢复"成立，需要三样，**一样都不存在**：

| 需要 | 现状 |
|---|---|
| 一个能**携带** session_id 的帧 | `auth` 只有 `ticket`，`additionalProperties: false`；`session.start` 只有 `material_id`/`scene_type`/`voice`。**协议没有让客户端自报家门的地方** |
| 会话**查找** | 网关按一次性票据路由，自铸 `session_id`；全包**没有任何** `GetSession`/`LoadSession`/会话注册表。每会话状态活在 `sessionRuntime`，连接断开即丢弃 |
| 活上下文的**持久化** | 音频序号水位线、在途轮次、provider 句柄 —— 都不存 |

而且**票据是一次性的**：重放旧票据 → `ErrTicketUsed` → `Unauthenticated("ticket already used")`。
换新票据 = app-server 建**新**会话、**新** uuid。所以 `session_id` 是**连接作用域、1:1**。

**结论**：这是一张独立的后端票（新帧 + 能活过滚动重启的注册表 + 活上下文持久化），**不是 P1-15 的修复**。

### 3.4 顺带核实出一条**文档与实现不符**（新台账项）

设计文档 `meta docs/30_技术方案/32` 第 239 行写着：

> 3 秒窗口内自动重连 + 携 `session_id` 恢复（**后端网关无状态、上下文在 Redis**，技术方案六章）

**"上下文在 Redis"在网关侧不成立**：`internal/`、`cmd/`、`pkg/` 里**零 Redis 依赖**，
`go.mod` 没有 Redis。Redis 只出现在 `deploy/docker-compose.yml` 与 README / 脚本里 —— **是基础设施与文档，不是代码**。

真正的位置是 **MySQL**，而且存的是**记录不是可恢复状态**（`practice_sessions` / `utterances` / `session_tickets`），
没有活会话上下文、没有音频水位线、没有 provider 句柄。

这与 P1-19（文案 5/12）、P1-20（阶段标签 3/13）、P1-18（冻结的死面）是**同一族**：
**单看每一处都像活的。** 已记入 `77_`。

## 4. 守卫测试：把"不重连"钉成事实

`networkLossDegradesAndNeverAttemptsAReconnect` 断言两件事：

1. `networkLost` → 窗口过后进入 `degradedText`
2. **`startSessionCallCount == 1`** —— 全程只建立过一次连接，就是用户点"开始"的那次

第二条是关键。`startSession()` 是唯一打开连接的入口（只由 `createSession` 调用，而它只在 `sessionStartTap` 时派发），
所以这个计数就是"连接尝试次数"。

**它的作用是让将来实现重连变成一件"必须 deliberate"的事**：谁接上了，这条就红，
逼他同时更新那些注释 —— 而不是让窗口悄悄变回一个看起来活着的装饰。

### 红验证：把重连真的接上

在窗口里加一句 `try? await speechClient.startSession()`（即真的尝试重连）：

```
✘ Test networkLossDegradesAndNeverAttemptsAReconnect() recorded an issue at
  SpeechSessionMiddlewareTests.swift:1145:9: Expectation failed:
  await speechClient.startSessionCallCount == 1
```

红的正是预料的那条。

> **本票的红/绿要说清楚**：这是一条**"能力缺席"的钉**，不是缺陷复现 ——
> 它在修复前就是绿的（当时它描述的事实本来就成立）。按 `agents/shared/defect-fix-discipline.md` 的例外一，
> 本票是**能力标注**，红/绿不适用于"复现"这一环；上面那次红验证证明的是**守卫咬得住**，
> 而不是"修复前会红"。

## 5. 为什么不删

`85_` 与 `91_` 早已把这件事写清楚了（"今天没有重连"），`91_` 甚至点名了 `processingReview` 是同一形状。
也就是说，**文档层面它不是未知，是已知**；未知的是"代码里它看起来还活着"。

删除会让三件事同时失去落点：
- ② 的**缝**（窗口时长、状态机分支、`completeReconnect`）—— 后端一旦补上恢复能力，这些就是现成的接点
- ① 的 **stage** —— 网关一旦发 `review`，接上就是一行
- `88_` §⑧ 的**两个实例** —— 删了就没有可指的样本了

**标记的代价是零运行时行为**，收益是"谁生产它"这个问题在代码里就有答案。
这也是 `P1-1`（B17）立的先例：*代码正确，坏在它的存在暗示了一项能力；所以修法是让状态可读。*

## 6. 影响面

| 维度 | 影响 |
|---|---|
| **运行时行为** | **零改动**。本票只加注释与一条测试，没有改任何执行路径 |
| **协议 / 后端** | **无**。后端那三样是**独立的后端票**，不在本票范围 |
| **测试** | 456 条不变（新增断言加在既有的 3 秒窗口测试里，**没有新增运行时开销**） |
| **可读性** | 7 个 artifact 各自回答了"谁生产它"。`Configuration.reconnectWindow` 现在明说自己不被读 |
| **已知未做** | 真正的重连能力（后半端票）；`ProcessingStage.review` 仍不可达，直到网关发 `review` |

## 7. 未做

- **实现重连** —— 见 §3.3，需要后端先做三样。
- **删除任何 artifact** —— 本票刻意不删（§5）。
- **`ProcessingStage.review` 的替代** —— 若最终决定"不做 review 这一步"，那时的动作是删 stage + 事件 + 超时预算；
  现在还不该定，因为后端可能加。
