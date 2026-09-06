# Skill I20 — Prompt 工程师接入(P0, W3 Day 1, 无依赖)

> **Master**: 待建 GitHub Issue `I20: iOS Prompt 工程师接入(V2.0 收口)`
> **Sub-tickets**: 4 (T-I20-1..4)
> **总工时**: 0.5 dev-day
> **阻塞**: 无
> **关联**: I21(同 W3 Day 1, 状态机联动), 38_ §1.2

---

## §0 Master Issue Body

**Title**: `I20: iOS Prompt 工程师接入(V2.0 收口)`
**Labels**: `ios`, `v2.0`, `priority: P0`, `prompt`, `state`
**Milestone**: `V2.0 W3`

```markdown
## 🎯 目标
iOS Prompt 工程师(V2.0 收口):
- ✅ 已完成:基础系统 prompt 注入 + 命中检测构造(V1.x)
- ⏸ 本 Issue:turn 超时兜底(60s) + outcome 上报 + Prompt 模板 V2.0(B7 hits 注入)

## 🚧 阻塞条件
- 无 backend 阻塞——W3 启动首日可立即创建并启动

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I20-1 | turn 超时兜底(60s → client.turn.abort) | 0.2d |
| T-I20-2 | outcome 枚举对齐 + 状态机联动 | 0.1d |
| T-I20-3 | SystemPromptBuilder V2.0(B7 hits + userLevel) | 0.1d |
| T-I20-4 | 埋点 + 单元测试 | 0.1d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- 架构:fluentwork-meta/docs/30_技术方案/38_I20收口与全链路架构设计.md §1.2
- 平行:I21 状态机扩展(同 W3 Day 1)
```

---

## §1 T-I20-1 — turn 超时兜底

**Labels**: `ios`, `v2.0`, `priority: P0`, `prompt`, `state`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
`SpeechSessionMachine` 添加 60s turn 超时监控,超时后发 `client.turn.abort` 帧给 backend。

## 📋 实施步骤
1. 在 `Shared/FluentWorkCore/SpeechSession/SpeechSessionMachine.swift` 添加:
   ```swift
   private var turnTimeoutTask: Task<Void, Never>?
   
   func startTurn() {
       state = .listening
       startRecording()
       turnTimeoutTask?.cancel()
       turnTimeoutTask = Task { [weak self] in
           try? await Task.sleep(nanoseconds: 60_000_000_000)
           guard !Task.isCancelled else { return }
           await MainActor.run { self?.handleTurnTimeout() }
       }
   }
   
   private func handleTurnTimeout() {
       stopRecording()
       Task {
           try? await webSocketClient.send(frame: ClientTurnAbortFrame(
               sessionID: currentSessionID,
               turnID: currentTurnID,
               outcome: "timeout"
           ))
       }
       state = .waitingForAIAnswer
       // 10s 后自动切 ended(由 I21 状态机处理)
   }
   ```
2. 与 I21 `waitingForAIAnswer` 状态联动

## ✅ 验收
- [ ] T-I20-1 60s turn 超时 → backend 收到 `client.turn.abort` outcome=timeout
- [ ] 超时不阻塞主流程(主线程安全)
- [ ] 状态机在等待期间不重复触发

## 🔗 依赖
- Blocked by: 无
- Blocks: I21 T-I21-3(waitingForAIAnswer UI)
- Master: I20
```

---

## §2 T-I20-2 — outcome 枚举对齐 + 状态机联动

**Labels**: `ios`, `v2.0`, `priority: P0`, `prompt`, `state`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
定义 `TurnOutcome` 枚举与 backend 对齐,在各时机上报正确 outcome。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/SpeechSession/TurnOutcome.swift`:
   ```swift
   enum TurnOutcome: String, Codable {
       case ok
       case timeout
       case userAbandoned = "user_abandoned"
       case error
   }
   ```
2. 在 `SpeechSessionMachine` 各时机上报:
   - 正常结束 → `.ok`
   - 超时(T-I20-1) → `.timeout`
   - 用户主动放弃 → `.userAbandoned`
   - 网络断开 → `.error`
3. `ClientTurnAbortFrame` 的 `outcome` 字段使用枚举 rawValue

## ✅ 验收
- [ ] T-I20-2 outcome 枚举 4 种场景都覆盖
- [ ] iOS 上报 = backend 记录的 outcome
- [ ] 38_ §1.2 的缺陷 #1(`outcome=ok` 误标)修复验证

## 🔗 依赖
- Blocked by: T-I20-1
- Blocks: 无
- Master: I20
```

---

## §3 T-I20-3 — SystemPromptBuilder V2.0

**Labels**: `ios`, `v2.0`, `priority: P0`, `prompt`, `llm`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
新建 `SystemPromptBuilder`,支持 B7 hits 注入 + 用户水平调整。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Prompt/SystemPromptBuilder.swift`:
   ```swift
   struct SystemPromptBuilder {
       static func build(
           basePrompt: String,
           recentHits: [RecordedHit],
           userLevel: UserLevel
       ) -> String {
           var prompt = basePrompt
           if !recentHits.isEmpty {
               prompt += "\n\n## 最近用户命中过的话术块:\n"
               for hit in recentHits {
                   prompt += "- \(hit.intentZh): \(hit.chunkEn)\n"
               }
           }
           prompt += "\n\n## 用户水平:\(userLevel.rawValue)"
           return prompt
       }
   }
   ```
2. `RecordedHit` 从 B19 backend 的 `recentHits` API 获取
3. `UserLevel` 枚举:beginner / intermediate / advanced(从 UserDefaults 或 API 获取)

## ✅ 验收
- [ ] T-I20-4 最近 8 个 hit block 出现在 system prompt
- [ ] T-I20-5 用户水平=advanced prompt 包含对应字段
- [ ] T-I20-6 无 hits 时 prompt 不变形

## 🔗 依赖
- Blocked by: 无
- Blocks: 无
- Master: I20
```

---

## §4 T-I20-4 — 埋点 + 单元测试

**Labels**: `ios`, `v2.0`, `priority: P0`, `prompt`, `observability`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
埋点增强 + 完整单元测试覆盖。

## 📋 实施步骤
1. 在 `Shared/FluentWorkDiagnostics/Tracker.swift` 添加:
   ```swift
   // turn 超时埋点
   Tracker.shared.log("turn.timeout", properties: [
       "session_id": sessionID,
       "turn_id": turnID,
       "elapsed_ms": 60000
   ])
   
   // outcome 分布埋点
   Tracker.shared.log("turn.outcome", properties: [
       "outcome": outcome.rawValue,
       "session_id": sessionID
   ])
   ```
2. 新建 `Tests/FluentWorkCoreTests/SpeechSessionPromptTests.swift`:
   - testTurnTimeout_TriggersAbortFrame
   - testOutcome_OkOnNormalEnd
   - testOutcome_TimeoutOn60s
   - testOutcome_UserAbandonedOnCancel
   - testSystemPromptBuilder_With8Hits
   - testSystemPromptBuilder_WithoutHits
   - testSystemPromptBuilder_UserLevelAdvanced

## ✅ 验收
- [ ] T-I20-8 turn.timeout event 上报
- [ ] T-I20-9 turn.outcome event 4 种 outcome 都触发
- [ ] 7 个单元测试全部 PASS

## 🔗 依赖
- Blocked by: T-I20-1, T-I20-2, T-I20-3
- Blocks: 无(Master 收口)
- Master: I20
```

---

## §5 执行顺序与总工时

```
T-I20-1 (0.2d) ──▶ T-I20-2 (0.1d) ──▶ T-I20-3 (0.1d) ──▶ T-I20-4 (0.1d)
```

**总工时**:0.5 dev-day
**推荐 Owner**:iOS 工程师 A
**关键路径**:T-I20-1 是基础,I20-4 依赖 I20-1/2/3 全部完成后收口
