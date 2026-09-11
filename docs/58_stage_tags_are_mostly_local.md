# 阶段标签：一份**没有**兑现的跨服务契约

**日期**：2026-09-11
**状态**：实现与测试已齐。
**对应**：meta `77_` **P1-20** · 与 `docs/54`（相位收敛）§2 同源

## 1. 为什么

`SpeechSessionPhase.stageTag` 的注释原本写着：

> Maps the iOS-side phase to the backend's `stage` log tag so the iOS
> `timing_phase_transition` log **lines up with** the backend's … events when
> they share the same session id.

**这句话对三个值成立，对其余全部不成立。**

网关 `stage` 的**全部**词汇是五个：`orchestration` / `asr` / `tts` / `scheduler` / `transport`。
而 iOS 的标签表长得多，其中大多数命名的是**服务端从不记的相位**。

## 2. 代价不是"文档不精确"，是**一次找错方向**

跨日志搜索是本项目排查的常规动作（`session_id` / `turn_id` / `log_id` 三个 join 键都在用）。
当一个字段**声称**是共享词汇时：

> 读的人会拿它去服务端日志里搜 —— **搜不到** —— 然后得出"这条事件丢了"的结论。

**搜不到和没发生过长得一模一样**，而这里其实是第三种情况：**这个标签从头到尾就只有客户端在说。**
这与 `77_` P1-18 / P1-19 是同一族 —— 单看每一处都像活的。

顺带：`ProcessingStage.stageTag` 的注释也写着"cross-service log tag"，同样的话，同样的错。

## 3. 修法：让声明**可验证**

按业界惯例，一个声称共享的关联字段要么兑现，要么改名/改声明。这里选**改声明**，并把重叠**钉住**：

1. `SpeechSessionPhase.stageTag` 的注释改成："**A label for this phase. Mostly iOS-local — not a backend vocabulary.**"
   并写明：`orchestration` / `asr` / `tts` 这三个真的能 join，其余不能。
2. `ProcessingStage.stageTag` 同样更正：**只有 `asr`** 是网关的 stage，另四个不是。
3. **新增 `StageTagVocabularyTests`**，把"哪几个真的 join"变成一个会被执行的事实。

**没有改任何标签字符串。** 已经读它们的东西（`timing_phase_transition` 的 `stage` 属性、
`speech_session_transition` 的 `to_label`）一个字节都不变 —— **变的是声明，不是数据。**

## 4. 测试

`Tests/FluentWorkCoreTests/SpeechSession/StageTagVocabularyTests.swift`，两条：

| 测试 | 断言 |
|---|---|
| `everyIOSStageTagIsEitherSharedOrExplicitlyLocal` | iOS 标签 ∩ 网关词汇 **恰好等于** `{orchestration, asr, tts}`；且"大多数是客户端本地"这句也成立 |
| `theSharedTagsSpellTheGatewayVocabularyExactly` | 三个共享值逐字对上；且 `llm` / `review` / `waiting_for_evaluation` / `waiting_for_ai_answer` **明确不在**网关词汇里 |

第二条里那四个"看起来像服务端词汇但不是"的最值得钉：它们是**将来最容易被重新声明成共享**的那几个。

### 红验证

把一个 iOS 标签改成网关的某个 stage（`waitingUser` → `"transport"`）：

```
✘ Test everyIOSStageTagIsEitherSharedOrExplicitlyLocal() recorded an issue at
  StageTagVocabularyTests.swift:45:9: Expectation failed:
  (iosTags.intersection(Self.gatewayStages) → ["asr", "orchestration", "tts", "transport"])
  == (Self.joined → ["asr", "tts", "orchestration"])
↳ the iOS/gateway stage overlap changed; update the doc comment on
  SpeechSessionPhase.stageTag and this set together
```

红的正是预料的那条，失败信息直接说该去改哪里。

### 门禁

```bash
swift test          # 464 tests passed  (462 + 2 新增)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

## 5. 顺带修掉一处叠了两层的注释

`stageTag` 上**叠着两个文档注释** —— P1-3 加了一个新的，旧的没删。旧的正是那句不成立的"mirrors the backend"。
已合并成一份，声明与事实一致。

## 6. 影响面

| 维度 | 影响 |
|---|---|
| **协议 / 后端** | **零改动**。本票是客户端声明与测试 |
| **标签字符串** | **一个都没改** —— 读它们的东西逐字不变 |
| **可发现性** | 三个能 join 的值现在写在注释里且被测试钉住；不能再 join 的也被写明 |
| **未做** | **没有让后端补生产那 10 个**。那要么是给每条 iOS 相位找一个服务端对应（多数并不存在），要么是把 iOS 的相位表缩到服务端那五个 —— 两者都会**削掉客户端真正需要的状态**，而 §3 的改声明已经消除了"找错方向"这个代价 |

## 7. 与 P1-3 的关系

P1-3（相位收敛）面对的正是这份"只兑现了一部分"的契约，并把它记进了 `docs/54` §2：
设计文档里那句"实现前先确认后端三个 stage 串的取值"，**答案是"三个里只有一个存在"**。
本票把那个观察从"实现时的一个注脚"变成了**被测试钉住的声明**。
