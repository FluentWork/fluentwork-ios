# Skill I21 — 状态机子状态扩展(P0, W3 Day 1, 无依赖)

> **Master**: 待建 GitHub Issue `I21: 状态机子状态扩展(V2.0)`
> **Sub-tickets**: 4 (T-I21-1..4)
> **总工时**: 0.5 dev-day
> **阻塞**: 无
> **关联**: I20(同 W3 Day 1, 联动 turn 超时), 32_ §四.2

---

## §0 Master Issue Body

**Title**: `I21: 状态机子状态扩展(V2.0)`
**Labels**: `ios`, `v2.0`, `priority: P0`, `state`
**Milestone**: `V2.0 W3`

```markdown
## 🎯 目标
V2.0 状态机从 5 状态扩为 7 状态:
- 新增 `waitingForAIAnswer`:turn 已发 + 60s 内未收到 ai.text.start
- 新增 `waitingForEvaluation`:turn 结束 + 等 eval.frame

## 🚧 阻塞条件
- 无 backend 阻塞——W3 启动首日可立即创建并启动

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I21-1 | 状态枚举扩展(5→7 states) | 0.1d |
| T-I21-2 | isValidTransition 规则(8 种合法) | 0.2d |
| T-I21-3 | SpeakingRoomView UI 绑定(新增 2 状态) | 0.1d |
| T-I21-4 | 状态转换埋点 + 单元测试 | 0.1d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- 架构:fluentwork-meta/docs/30_技术方案/32_FluentWork-iOS App端技术设计文档.md §四.2
- 平行:I20 Prompt 工程师(同 W3 Day 1, 联动 waitingForAIAnswer)
```

---

## §1 T-I21-1 — 状态枚举扩展

**Labels**: `ios`, `v2.0`, `priority: P0`, `state`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
`SpeechSessionState` 枚举从 5 个扩展为 7 个。

## 📋 实施步骤
1. 修改 `Shared/FluentWorkCore/SpeechSession/SpeechSessionState.swift`:
   ```swift
   enum SpeechSessionState: Equatable {
       case idle
       case listening
       case processing
       case speaking
       case ended(outcome: TurnOutcome)
       case waitingForAIAnswer   // ✨ V2.0 新增
       case waitingForEvaluation // ✨ V2.0 新增
   }
   
   // 添加 label 属性用于埋点
   extension SpeechSessionState {
       var label: String {
           switch self {
           case .idle: return "idle"
           case .listening: return "listening"
           case .processing: return "processing"
           case .speaking: return "speaking"
           case .ended: return "ended"
           case .waitingForAIAnswer: return "waiting_for_ai_answer"
           case .waitingForEvaluation: return "waiting_for_evaluation"
           }
       }
   }
   ```
2. 确认 `TurnOutcome` 从 I20 T-I20-2 共享

## ✅ 验收
- [ ] 编译通过,无警告
- [ ] 7 个状态的 label 属性正确

## 🔗 依赖
- Blocked by: I20 T-I20-2(TurnOutcome 枚举)
- Blocks: T-I21-2
- Master: I21
```

---

## §2 T-I21-2 — isValidTransition 规则

**Labels**: `ios`, `v2.0`, `priority: P0`, `state`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
实现 `isValidTransition` 规则,支持 8 种合法转换 + 拒绝非法转换。

## 📋 实施步骤
1. 修改 `Shared/FluentWorkCore/SpeechSession/SpeechSessionMachine.swift`:
   ```swift
   private func isValidTransition(from old: SpeechSessionState, to new: SpeechSessionState) -> Bool {
       switch (old, new) {
       // 正常流程
       case (.idle, .listening),
            (.listening, .processing),
            (.processing, .speaking),
            (.speaking, .ended),
            // 用户打断
            (.speaking, .listening),
            // I20 超时兜底
            (.listening, .waitingForAIAnswer),
            (.waitingForAIAnswer, .ended),
            // 评价等待
            (.ended, .waitingForEvaluation),
            (.waitingForEvaluation, .ended):
           return true
       default:
           return false
       }
   }
   ```
2. 无效转换时输出警告日志 + 不更新状态(防御性)
3. 每次状态转换触发 `state.transition` 埋点

## ✅ 验收
- [ ] T-I21-1~T-I21-5 5 种合法转换 PASS
- [ ] T-I21-6 ~T-I21-7 超时 → waitingForAIAnswer → ended 链路 PASS
- [ ] T-I21-8 ~T-I21-9 ended → waitingForEvaluation → ended 链路 PASS
- [ ] T-I21-10 无效转换(如 idle→speaking)被拒绝

## 🔗 依赖
- Blocked by: T-I21-1
- Blocks: T-I21-3
- Master: I21
```

---

## §3 T-I21-3 — SpeakingRoomView UI 绑定

**Labels**: `ios`, `v2.0`, `priority: P0`, `ui`, `state`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
`SpeakingRoomView` 添加 `waitingForAIAnswer` + `waitingForEvaluation` 两个新状态的 UI。

## 📋 实施步骤
1. 在 `Shared/FluentWorkCore/Architecture/Features/SpeakingRoomFeature.swift` 的 View 部分添加:
   ```swift
   case .waitingForAIAnswer:
       VStack {
           ProgressView()
           Text("AI 思考中…(最长 10s)").font(.caption)
       }
       .frame(maxWidth: .infinity, maxHeight: .infinity)
   
   case .waitingForEvaluation:
       VStack {
           ProgressView()
           Text("正在评价本次表现…").font(.caption)
       }
       .frame(maxWidth: .infinity, maxHeight: .infinity)
   ```
2. 确保 `HoldToSpeakButton` 在 `waitingFor*` 状态隐藏
3. 与 I20 T-I20-1 联动:60s 超时触发 `waitingForAIAnswer`

## ✅ 验收
- [ ] waitingForAIAnswer 状态显示「AI 思考中…」加载态
- [ ] waitingForEvaluation 状态显示「正在评价…」加载态
- [ ] 两个新状态切换流畅无闪烁

## 🔗 依赖
- Blocked by: T-I21-2, I20 T-I20-1
- Blocks: T-I21-4
- Master: I21
```

---

## §4 T-I21-4 — 状态转换埋点 + 单元测试

**Labels**: `ios`, `v2.0`, `priority: P0`, `state`, `observability`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
状态转换埋点 + 完整单元测试覆盖。

## 📋 实施步骤
1. 在 `SpeechSessionMachine.transition` 方法中触发:
   ```swift
   Tracker.shared.log("state.transition", properties: [
       "from": oldState.label,
       "to": newState.label,
       "session_id": currentSessionID
   ])
   ```
2. 新建 `Tests/FluentWorkCoreTests/SpeechSessionStateMachineTests.swift`:
   - testValidTransition_idleToListening
   - testValidTransition_listeningToProcessing
   - testValidTransition_processingToSpeaking
   - testValidTransition_speakingToEnded
   - testValidTransition_speakingToListening_interrupt
   - testValidTransition_listeningToWaitingForAIAnswer_timeout
   - testValidTransition_waitingForAIAnswerToEnded
   - testValidTransition_endedToWaitingForEvaluation
   - testValidTransition_waitingForEvaluationToEnded
   - testInvalidTransition_idleToSpeaking
   - testInvalidTransition_anyToIdle
   - testInvalidTransition_waitingForEvaluationToListening

## ✅ 验收
- [ ] T-I21-11 state.transition event 埋点上报
- [ ] 12 个状态机单元测试全部 PASS
- [ ] UI 渲染测试:7 个状态在 SpeakingRoomView 中正确显示

## 🔗 依赖
- Blocked by: T-I21-3
- Blocks: 无(Master 收口)
- Master: I21
```

---

## §5 执行顺序与总工时

```
T-I21-1 (0.1d) ──▶ T-I21-2 (0.2d) ──▶ T-I21-3 (0.1d) ──▶ T-I21-4 (0.1d)
                 ↑
         依赖 I20 T-I20-2
```

**总工时**:0.5 dev-day
**推荐 Owner**:iOS 工程师 A(与 I20 同期)
**关键路径**:I20 T-I20-2 先完成提供 TurnOutcome,I21 才能开始
