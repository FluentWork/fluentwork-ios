# 错误码文案：从 5/12 到全覆盖，且补上一直缺的那条守卫

**日期**：2026-09-11
**状态**：实现与测试已齐。
**对应**：meta `77_` **P1-19**

## 1. 为什么

网关能发的 `error.code` 有 **12 个**，iOS 的文案表只覆盖 **5 个**：

| 有文案 ✅ | 只给机器码 ❌ |
|---|---|
| `provider_audio_failed` | `provider_start_failed` |
| `provider_control_failed` | `provider_interrupt_failed` |
| `provider_open_failed` | `end_failed` |
| `activate_failed` | `idle_timeout` |
| `client_asr_required` | `invalid_frame` |
| | `session_not_started` |
| | `already_authenticated` |

**这个切分没有任何设计理由** —— 最刺眼的是前四个：`provider_audio_failed` / `provider_control_failed` / `provider_open_failed` / `provider_start_failed` 是同一个子系统的同一个错误族，**前三个有文案，第四个没有**。

## 2. 为什么没有任何测试发现它

**因为"少一条"不是错误。**

```swift
default:
    return rawMessage?.isEmpty == false ? "[\(code)] \(rawMessage ?? "")" : "[\(code)]"
```

兜底分支**总是**能产出一个字符串。少写一个 `case` 不会红，只会让用户看到
`[provider_start_failed] use of closed network connection`。

这正是台账说的"**新增错误码不会触发任何测试**：文案表与错误码表必须一起维护" ——
但当时**没有东西可以"一起维护"**。

### 顺带核实：共享 schema 有意不枚举

`schemas/transport/wss-control-frames-{v1,v2}.json` 里 `error.code` 是 **自由字符串**，没有 `enum`。

这是**对的**，不是遗漏：给 `code` 加 `enum` 会让**每一个新增错误码都变成 schema 违约** ——
正是 P1-12 / P1-20 记的那类前向兼容陷阱。所以修法**不能**是把码表塞进 schema，只能在客户端把这层补齐。

## 3. 修法

**一、补齐 12 个码的文案。** 上游错误族补全（含 `provider_start_failed`）；另外四个按性质分：

- `end_failed` → "结束练习时出了点问题，请返回工作台重试"
- `idle_timeout` → "长时间没有操作，这次练习已经结束"
- `invalid_frame` / `session_not_started` / `already_authenticated` → "客户端状态异常，请重试"（**我们自己**的 bug，不该让用户以为是自己说了什么）

**二、兜底改成"人话在前，标识在后"。**

```swift
default:
    return "语音服务出了点问题，请重试（\(code): \(raw)）"
```

未知的码**仍然带上标识符** —— 但作为**人话的附录**，而不是替代人话。理由是两个方向同时成立：

- 没见过的码，**恰恰是支持需要标识符**的时候
- 也**恰恰是不能只给用户看标识符**的时候

旧写法 `[code] raw` 把这两件事做反了：诊断信息在前，人话完全没有。

**三、`userFacingErrorText` 从 `private` 改成 internal**，让测试够得着。

## 4. 测试

新增 `SocketTransportEventMapperErrorCopyTests`，四条：

| 测试 | 断言 |
|---|---|
| `everyGatewayErrorCodeRendersAsCopy` | **参数化跑全部 12 个码**，每个都要有自己的文案 |
| `knownCodesDoNotLeakRawSocketText` | 已知码**不得**泄漏原始 socket 文本（`broken pipe`） |
| `anUnknownCodeKeepsItsIdentifierBesideAHumanSentence` | 未知码：有人话、有标识符、且**人话在前** |
| `anEmptyRawMessageDoesNotLeaveADanglingSeparator` | `nil` / 空串不留悬空冒号 |

句表就在测试里，**来源写明是 `internal/voicegateway/handler.go` 的 `ErrorFrame{...}` 调用点**，
并注明"那边加码，这边加行" —— 这就是那句"必须一起维护"的落点。

### 红验证

把 `provider_start_failed` 从文案表里删掉（退回兜底）：

```
✘ Test everyGatewayErrorCodeRendersAsCopy(code:) with 12 test cases failed …
  code → "provider_start_failed" … Expectation failed:
  !((text → "语音服务出了点问题，请重试（provider_start_failed: use of closed network connection）")
    .contains("use of closed network connection") → true)
↳ provider_start_failed fell through to the generic fallback

✘ Test knownCodesDoNotLeakRawSocketText() … Expectation failed:
  !((text → "…（provider_start_failed: write tcp 1.2.3.4:5678: broken pipe）").contains("broken pipe"))
```

**两条守卫同时咬住**，参数化那条还直接点名是哪個码。

## 5. 一处旧契约被改动，以及它牵出的第三个发现

`SpeakingRoomTransportBridgeTests.mapperConvertsUnsupportedFrameToFailedAction` 原本断言：

```swift
#expect(action == .failed("[unsupported_frame] unknown type"))
```

**它钉住的正是本票要废掉的那个格式**（`[code] raw`）。按纪律"旧契约被钉在别的测试里是常态，那就连同测试一起更新，并写明为什么旧契约不成立"：

> 旧契约不成立，因为 `[code] raw` 这个形状本身就是 P1-19 判定的问题 —— 诊断信息在前、人话缺失。
> 该测试的**意图**（"联调 must not see this code after abort"）不变，变的是它期望的字符串形状。

**顺带发现：`unsupported_frame` 已经被废弃。** 它现在只出现在 `handler.go` 的注释里，
而且注释说的正是"不再发它"（`handler.go:667`：*Ignoring unknown types. Emitting unsupported_frame used to map to…*）。

所以这条测试**恰好落在未知码路径上** —— 更新后的断言同时覆盖了"退役的码仍产出人话 + 保留标识符"。
已在测试注释里写明，避免下一个人以为它还活着。

> 这条与 P1-12 是同一件事的两端：客户端那边刚修好"未知帧类型不再断开连接"，
> 服务端这边的 `unsupported_frame` 早已退役。两端现在都按"不认识就忽略"行事。

## 6. 影响面

| 维度 | 影响 |
|---|---|
| **协议 / 后端** | **无改动**。共享 schema 有意不枚举 `code`，本票也不去动它 |
| **用户可见文案** | 7 个此前显示机器码的码现在显示人话；未知码的**形状**从 `[code] raw` 变成「人话（code: raw）」 |
| **诊断能力** | 未减弱：未知码仍带 `code` 与原始 message |
| **测试** | 462 条（458 + 4 新增）；**一条既有测试的断言被更新**，原因见 §5 |

## 7. 未做

- **没有把码表做成跨仓契约**（schema enum）。理由见 §2：那会把新增码变成 schema 违约，是前向兼容的反面。
  句表与注释里的来源说明是当前能做到的最好形式。
- **没有校验文案的"质量"**。守卫能保证"每个码都有文案"，保证不了文案说得对 —— 后者是人看的。
- **`SocketTransportError.userFacingMessage`（传输层自己的错误）仍是英文**，与网关错误码这套中文文案并存。
  两者来源不同（一个是本机传输层，一个是服务端），本票未合并它们。
