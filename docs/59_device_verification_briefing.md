# 真机验证简报：P1-6 与 P1-8

**日期**：2026-09-11
**定位**：这两条**只能真机验**，代码侧没有可复现的失败。本文给**完整语境** ——
要回答什么问题、怎么准备、看到什么算过、看到什么算不过、不过的话代码在哪。

**前置**：本地栈在跑（`./scripts/dev-up.sh`）· 真机与 Mac 同网段 ·
`AppEnvironment.local(host:)` 指向 Mac 的 IP。

---

# P1-6 — `abort` 之后 ASR 会不会串味

## 要回答的问题

用户在录音中途点了中止（`client.turn.abort`），**那一轮已经送上去的音频，会不会出现在下一轮的转录里？**

## 为什么它有可能发生

火山的上游 duplex **没有 `clear` API**。网关的处理是**重建整个 duplex**（`resetDuplex`），
而重建发生在**转发中止之后** —— 上游缓冲区里那一轮已经收到的音频，**没有任何一个调用能告诉它"忘掉"**。

所以问题不是"有没有清"，而是"**重建这个动作，在时序上是否足以让残留到不了下一轮**"。
这个问题**代码读不出来** —— 它取决于上游在什么时刻把缓冲区交给下一轮的响应。

台账 `77_` 的原话：「火山无 `clear` API，网关改为重建 duplex；待真机确认」。

## 怎么准备

需要：**前一轮说一段有辨识度的话 → 中途中止 → 等 2 秒 → 说完全不同的话**。

辨识度是判据的全部：两轮内容必须**不可能互相混淆**，否则"串味"和"我说了相似的话"分不开。

推荐配对（都用中文，语速正常）：

| 轮 | 说什么 | 中止时机 |
|---|---|---|
| 第 1 轮 | 「**蓝鲸在深海用声呐交流，频率很低**」 | **说到"频率"就点中止**（不要说完） |
| 第 2 轮 | 「**今天下午三点开会，会议室在三楼**」 | 说完，正常等回复 |

## 看什么

**判据是转录文本，不是听感。** 找第 2 轮的 `client.asr.transcription`（或后端的
`transcript` 字段），看它是否**含第 1 轮的词**（蓝鲸 / 声呐 / 深海 / 频率）。

| 现象 | 结论 |
|---|---|
| 第 2 轮转录只有第 2 轮的话 | **不串味** ✅ |
| 第 2 轮转录里混进"蓝鲸/声呐/频率" | **串味** ❌ |
| 第 2 轮转录为空 / 明显被截断 | **另一种问题**（残留挤掉了新内容），也要记 |

还要看**第 1 轮有没有被落库**：中止的轮次**不应该**产生一条完整 utterance。
（它的正确去向是 `client.turn.abort` + `outcome=user_abandoned`。）

**最少做 3 次**：这是个时序问题，一次通过说明不了什么。三次里有一次串味就成立。

## 不过的话，代码在哪

- 重建时机与顺序：`internal/voicegateway/provider_volc_duplex.go` 的 `resetDuplexFn` / `resetAfterTurnReadFailure`
- 中止路径：`typeClientTurnAbort` 分支（`handler.go`）
- **注意一个已被论证过的坑**：重建会新建 provider session。F18 修过"重开把音频序号从 1 重来"，
  所以**如果验证中发现音频缺失**，先怀疑序号而不是 ASR。

---

# P1-8 — 徽章与音频是两个时钟

## 要回答的问题（三条，按可验证性排序）

| # | 问题 | 判据 |
|---|---|---|
| **a** | 徽章显示 **4 秒**，而长回复的音频可能放 **20 秒以上** —— **用户看得见吗？** | **人的判断**，不是日志 |
| **b** | 徽章在评估超时**之后**才到，状态机会不会不认？ | 日志 + 行为 |
| **c** | `EvaluationArrivalBox` 是**单槽布尔、不按轮** —— 会不会残留到下一轮，让下一轮跳过 20s 计时器？ | 日志 |

## 背景（F19 改了什么、没改什么）

`904316f` 只动了一个转移的副作用列表：从 `(.waitingForEvaluation, .evaluationTimedOut)` 移除 `.stopPlayback`。

**以下全部没动**：

| 组件 | 现状 |
|---|---|
| `feedback.badge` 的处理 | `badgeHit` 与 `evaluationReceived` **无条件派发** |
| 徽章渲染 | `BadgeFeedbackFeature` 按**时间**过滤，**不看相位** |
| 状态机的 `evaluationReceived` | 只在评估阶段有分支 |
| `EvaluationArrivalBox` | 未动 |

**真实耦合——两个时钟又碰上了**：

```
评估窗口   evaluationWait        = 20s    （固定预算）
徽章可见   visibleWindowSeconds  = 4s     （固定预算，BadgeFeedbackFeature.swift:94）
播放       ── 由 AI 说了多长决定 ── 无上界
```

F19 之前 20s 超时会把音频剪断，所以"徽章出现时房间是安静的"。**现在音频继续**，
于是长回复会盖过徽章 4 秒的**整个**显示窗口 —— 用户注意力在听，可能根本看不到徽章。

> 这与 F19 是**同一类错误**（用一个固定时钟去管一件长度由内容决定的事），只是方向相反。

## ⚠️ 准备这一步最容易踩空

**真机必须有自己的语料，否则徽章永远不会出现 —— 而且不会报错。**

`dev-up.sh` 的自动灌库写死 `device_id=corpus-seed-dev-device`，而**真机永远不是这个 id**。
语料按 `user_id` 隔离（`GET /internal/v1/corpus/blocks?user_id=`），所以真机那边语料是**空的**。

**先确认再开始**：真机的 `user_id` 下语料是不是 0 条。是 0 的话灌库：

```bash
cd fluentwork-backend
go run ./cmd/corpus-seed -device-id <真机 device_id>
```

（`device_id` 从 iOS 日志或 Keychain 取；历史上见过形如 `DA87E7D4-1371-4984-AD3F-D6D70B4D17D2`。
灌完应为 10 条。）

**灌进去的 10 条锚点（说左边，命中右边）**：

| 说 | 命中徽章 |
|---|---|
| I am blocked on the API review. | I'm blocked on the API review. |
| how about we pair on this tomorrow | How about we pair on this tomorrow? |
| I don't want to push the deadline | I'd rather not push the deadline. |
| thanks for your time | Thanks for your time today. |
| let's ship it | Let's ship it. |
| could you clarify | Could you clarify what you mean by that? |
| does that work for you | Does that work for you? |
| I'm not sure yet | I'm not 100% sure yet, but I'll confirm by EOD. |
| let's wrap up the meeting | Let's wrap up. |
| bottom line | Bottom line: we'll ship next Tuesday. |

> **DEBUG 版的注入徽章按钮**走的是 `badgeHit` **直通路径**，**绕过后端检测** ——
> 它验的是渲染，不是命中。**两者要分开看**：用直通按钮验 a 是可以的，验 b/c 不行。

## (a) 4 秒窗口 vs 播放长度 —— 人的判断

**做法**：说一句能命中徽章的话，然后让 AI 给一段**长**回复（`bottom line` 这类容易引出收尾长句）。

**看的是**：徽章出现的那一刻，你在听音频 —— **你注意到徽章了吗？**

**这一条没有日志判据**，台账也写明了：「判据是"用户看得见吗"，不是日志」。
所以要多做几次、并且**如实记录注意力状态**（"我在听，没看见"是有用数据，"我盯着屏幕所以看见了"不是）。

**如果结论是"看不见"**：那是**产品判断**（窗口该多长），不是 bug。改的是
`BadgeFeedbackFeature.visibleWindowSeconds`，但**先定产品意图再改数**。

## (b) 超时后到达的徽章，状态机不认

**机制**：状态机只有 `(.processing, .evaluationReceived) where stage == .evaluation` 这一条分支。
徽章在 20s **之后**到达时，机器已经离开评估阶段 → **徽章会显示**（`badgeHit` 无条件派发），
但机器**不把"评估已到"记下来**。

**做法**：说一句命中徽章的话，**在 20s 内不要说话**，等超过 20s 再等徽章。

**看什么**：`feedback.badge` 到达时机器在哪个阶段（tracker 的 `speech_session_transition` /
`phase_transition`，或后端日志的 `ai.turn.end` 时刻）。

**要判断的是**：这个"不记"**有没有害**。台账说 `b` 需要**先定性**（是否真的有害），
所以这一条的目标是把事实拿到，而不是急着修。**如果有害，影响面在它是否喂给 turn outcome / 回顾页** ——
先查这两处有没有读它。

## (c) `EvaluationArrivalBox` 不按轮

**机制**（`SpeechSessionMiddleware.swift:275`）：单槽布尔，`mark()` 置位、`consume()` 清位，
**只在会话起止 `reset()`**。

**假说**：徽章若在机器已离开评估阶段后到达，标记会**残留到下一轮**，
使下一轮进入该阶段时 `consume()` 返回 `true` → **跳过 20s 计时器**。

**做法**：造出"徽章迟到"的一次（同 b），**紧接着开始下一轮**，说一句命中徽章的其他话。

**看什么**：下一轮的评估阶段**有没有** `scheduleEvaluationWaitTask` 被调度的痕迹 ——
tracker 里有没有 `evaluation_timeout` 类事件，或者那一轮是否**不等超时就跳走**。

**这是既有问题，F19 没引入。** 验出来有害再修；修法方向是把它按轮（它已经有 `reset()`，
缺的是调用时机）。

---

# 记录建议

两条都建议：**每次都记"第几次"**，并**贴原始日志行**（转录文本 / tracker 事件），
不要只写结论。时序问题的结论在单次上不可信，而在转述里更不可信。

验完把结果写回 `77_` 对应行 —— 通过就标 ✅ 并注明"真机已验 + 日期"，
不通过就把**失败那次的原始输出**贴进该行。
