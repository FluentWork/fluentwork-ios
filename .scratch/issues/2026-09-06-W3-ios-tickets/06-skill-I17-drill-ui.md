# Skill I17 — 闪测 UI(P0, W4 Day 3, B22 CLOSED 后)

> **Master**: 待建 GitHub Issue `I17: 闪测 UI(E1/E4/E5)`
> **Sub-tickets**: 6 (T-I17-1..6)
> **总工时**: 1.5 dev-day
> **阻塞**: B22(闪测模块 backend CLOSED)
> **关联**: I15(TTSPlayer 复用), D-3 Ark Mini 判定 P90 ≤ 1.5s

---

## §0 Master Issue Body

**Title**: `I17: 闪测 UI(E1/E4/E5)`
**Labels**: `ios`, `v2.0`, `priority: P0`, `ui`, `drill`
**Milestone**: `V2.0 W4`

```markdown
## 🎯 目标
实现 PRD §E1/E4/E5 闪测完整 UI:
- E1 召回闪测:从调度队列拉 10 题,顺序训练卡流
- E4 结算页:本轮正确率 + 错题回放 + 「下一轮」按钮
- E5 推送:每日 09:00 本地通知提醒

## 🚧 阻塞条件
- B22(闪测模块 backend)CLOSED——GET /drill/round + POST /drill/judge

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I17-1 | DrillModels + DrillClient API | 0.2d |
| T-I17-2 | DrillTrainView + ViewModel | 0.5d |
| T-I17-3 | HoldToSpeakButton 集成 + ASR | 0.2d |
| T-I17-4 | DrillSummaryView + 错题列表 | 0.3d |
| T-I17-5 | 推送(本地通知) | 0.2d |
| T-I17-6 | Snapshot测试 + i18n | 0.1d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- REST:fluentwork-meta/docs/30_技术方案/48_FluentWork_V2_REST接口契约冻结_2026-09-06.md §1.5
- I15 复用:TTSPlayer(共用 Opus 解码器)
- 决策:fluentwork-meta/docs/40_研发流程与协作/47_D1_D5_开放技术决策备忘录_2026-09-03.md §D-3+§D-4
```

---

## §1 T-I17-1 — DrillModels + DrillClient API

**Labels**: `ios`, `v2.0`, `priority: P0`, `drill`, `networking`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
定义闪测数据模型 + 实现 DrillClient API。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkNetworking/DrillClient.swift`:
   ```swift
   public final class DrillClient {
       private let client: AuthenticatedNetworkClient
       
       public func getRound(size: Int = 10) async throws -> DrillRound {
           try await client.get("/drill/round?size=\(size)")
       }
       
       public func judge(roundID: String, blockID: String, audio: Data, asrText: String) async throws -> DrillJudgeResult {
           let body = JudgeRequest(roundID: roundID, blockID: blockID, audio: audio, asrText: asrText)
           return try await client.post("/drill/judge", body: body)
       }
   }
   
   public struct DrillRound: Codable {
       public let roundID: String
       public let items: [DrillItem]
       public let startedAt: Date
   }
   
   public struct DrillItem: Codable, Identifiable {
       public var id: String { blockID }
       public let blockID: String
       public let chunkEn: String
       public let intentZh: String
       public let audioURL: String
       public let timeoutMs: Int
   }
   
   public struct DrillJudgeResult: Codable {
       public let blockID: String
       public let semanticMatch: Bool
       public let semanticScore: Double
       public let nextDueAt: Date
       public let stateTransition: String
   }
   ```

## ✅ 验收
- [ ] API 调用编译通过
- [ ] 错误码正确处理(5xx 重试,4xx 展示用户提示)

## 🔗 依赖
- Blocked by: B22 CLOSED
- Blocks: T-I17-2, T-I17-3, T-I17-4
- Master: I17
```

---

## §2 T-I17-2 — DrillTrainView + ViewModel

**Labels**: `ios`, `v2.0`, `priority: P0`, `drill`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现闪测训练卡流 View + ViewModel。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Drill/DrillTrainView.swift`:
   ```swift
   public struct DrillTrainView: View {
       @StateObject private var viewModel: DrillTrainViewModel
       
       public init(viewModel: DrillTrainViewModel) {
           _viewModel = StateObject(wrappedValue: viewModel)
       }
       
       public var body: some View {
           VStack(spacing: 20) {
               // 进度条
               ProgressView(value: Double(viewModel.currentIndex), total: Double(viewModel.round.items.count))
                   .padding(.horizontal)
               
               // 题目卡
               if let item = viewModel.currentItem {
                   DrillCardView(item: item)
               }
               
               // AI TTS 预生成播放
               Button("🔊 听标准发音") {
                   viewModel.playStandardAudio()
               }
               
               // 用户录音
               HoldToSpeakButton(
                   isRecording: $viewModel.isRecording,
                   onStart: { viewModel.startRecording() },
                   onStop: { audio in Task { await viewModel.judge(audio: audio) } }
               )
               
               // 判定结果
               if let result = viewModel.lastResult {
                   ResultToast(result: result)
               }
           }
           .task { await viewModel.loadRound() }
       }
   }
   ```
2. 新建 `DrillTrainViewModel.swift`:
   - `loadRound()`:GET /drill/round
   - `judge(audio)`:ASR 识别 → POST /drill/judge → 更新 lastResult
   - 2s 后自动进入下一题

## ✅ 验收
- [ ] T-I17-1 启动闪测 → 拉 10 题
- [ ] T-I17-2 按住录音 → AI 判定 ≤ 2s 显示 result
- [ ] T-I17-3 全部 10 题答完 → 跳转结算页

## 🔗 依赖
- Blocked by: T-I17-1
- Blocks: T-I17-6
- Master: I17
```

---

## §3 T-I17-3 — HoldToSpeakButton 集成 + ASR

**Labels**: `ios`, `v2.0`, `priority: P0`, `drill`, `audio`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
闪测中复用 HoldToSpeakButton + LiveAudioEngine ASR。

## 📋 实施步骤
1. 在 `DrillTrainViewModel.judge` 中:
   ```swift
   func judge(audio: Data) async {
       isJudging = true
       defer { isJudging = false }
       do {
           let asrText = await ASREngine.shared.recognize(audio: audio)
           let result = try await api.judge(
               roundID: round.roundID,
               blockID: currentItem!.blockID,
               audio: audio,
               asrText: asrText
           )
           lastResult = result
           // 2s 后下一题
           try? await Task.sleep(nanoseconds: 2_000_000_000)
           lastResult = nil
           currentIndex += 1
       } catch {
           self.error = error
       }
   }
   ```
2. `ASREngine` 复用 `LiveAudioEngine` 的识别能力
3. 录音超时(8s)自动提交

## ✅ 验收
- [ ] ASR 识别正确
- [ ] T-I17-9 录音超时(8s)自动提交
- [ ] T-I17-10 后端 judge 5xx 显示重试按钮

## 🔗 依赖
- Blocked by: T-I17-1
- Blocks: T-I17-6
- Master: I17
```

---

## §4 T-I17-4 — DrillSummaryView + 错题列表

**Labels**: `ios`, `v2.0`, `priority: P0`, `drill`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现结算页 + 错题列表 View。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Drill/DrillSummaryView.swift`:
   ```swift
   public struct DrillSummaryView: View {
       let results: [DrillJudgeResult]
       let onNextRound: () -> Void
       let onExit: () -> Void
       
       private var accuracy: Double {
           guard !results.isEmpty else { return 0 }
           return Double(results.filter { $0.semanticMatch }.count) / Double(results.count)
       }
       
       public var body: some View {
           VStack(spacing: 24) {
               Text("本轮完成 🎉").font(.title)
               Text(String(format: "%.0f%%", accuracy * 100))
                   .font(.system(size: 64, weight: .bold))
                   .foregroundStyle(accuracy >= 0.8 ? .green : .orange)
               Text("\(results.count) 题,正确 \(results.filter { $0.semanticMatch }.count) 题")
               
               if !results.filter({ !$0.semanticMatch }).isEmpty {
                   NavigationLink("查看错题") {
                       DrillWrongListView(
                           results: results.filter { !$0.semanticMatch },
                           onReplay: { /* TODO */ }
                       )
                   }
               }
               
               Button("再来一轮") { onNextRound() }
                   .buttonStyle(.borderedProminent)
               Button("返回") { onExit() }
           }
       }
   }
   ```
2. 新建 `DrillWrongListView`:展示 chunk + 评分 + 改进建议
3. 中途退出:进度持久化到 UserDefaults(可恢复)

## ✅ 验收
- [ ] T-I17-4 准确率 ≥ 80% 绿色鼓励
- [ ] T-I17-5 准确率 < 50% 红色 + 复习入口
- [ ] T-I17-6 错题列表正确
- [ ] T-I17-12 中途退出 → 重入进度恢复

## 🔗 依赖
- Blocked by: T-I17-2
- Blocks: T-I17-6
- Master: I17
```

---

## §5 T-I17-5 — 推送(本地通知)

**Labels**: `ios`, `v2.0`, `priority: P0`, `drill`, `notifications`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现每日 09:00 本地通知(E5)。

## 📋 实施步骤
1. 在 `App/FluentWorkHost/FluentWorkHostApp.swift` 或 `AppBootstrapMiddleware`:
   ```swift
   func requestNotificationPermission() {
       UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { granted, _ in
           if granted {
               self.scheduleDailyDrillReminder()
           }
       }
   }
   
   func scheduleDailyDrillReminder() {
       let content = UNMutableNotificationContent()
       content.title = "今日闪测"
       content.body = "今日 5 题待复习,来巩固你的职场英语!"
       content.sound = .default
       
       var dateComponents = DateComponents()
       dateComponents.hour = 9
       dateComponents.minute = 0
       
       let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
       let request = UNNotificationRequest(identifier: "daily-drill", content: content, trigger: trigger)
       UNUserNotificationCenter.current().add(request)
   }
   ```
2. 推送权限请求时机:用户在闪测页首次进入时(不抢首次启动)

## ✅ 验收
- [ ] T-I17-7 推送权限请求对话框
- [ ] T-I17-8 每日 09:00 通知显示
- [ ] 权限拒绝时闪测功能仍可用

## 🔗 依赖
- Blocked by: 无(独立功能)
- Blocks: T-I17-6
- Master: I17
```

---

## §6 T-I17-6 — Snapshot测试 + i18n + D-3 性能

**Labels**: `ios`, `v2.0`, `priority: P0`, `drill`, `testing`, `i18n`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
Snapshot 测试 + i18n + D-3 P90 ≤ 1.5s 验证。

## 📋 实施步骤
1. 新建 `Tests/FluentWorkCoreTests/DrillViewSnapshotTests.swift`:
   - testDrillTrainView_Default
   - testDrillTrainView_Judging
   - testDrillSummaryView_HighAccuracy
   - testDrillSummaryView_LowAccuracy
   - testDrillWrongListView
2. i18n:所有用户可见字符串支持中英
3. D-3 性能:AI 判定 loading 文本「AI 判定中...」不超过 2s

## ✅ 验收
- [ ] 5 个 Snapshot PASS
- [ ] T-I17-11 离线状态显示提示
- [ ] T-I17-13 D-3 判定延迟 loading 文本
- [ ] T-I17-14 VoiceOver 每张卡片可朗读

## 🔗 依赖
- Blocked by: T-I17-2, T-I17-3, T-I17-4, T-I17-5
- Blocks: 无(Master 收口)
- Master: I17
```

---

## §8 I17 — 阻塞与对应

- **Blocked by**: [FluentWork/fluentwork-backend#48 (B22 闪测)](https://github.com/FluentWork/fluentwork-backend/issues/48) 状态为 CLOSED
- 跨仓对应文件:`fluentwork-backend/.scratch/issues/2026-09-06-W3-backend-tickets/08-skill-B22-drill-privacy.md`(含 #74-#83 10 个 backend sub-ticket)
- 跨仓评审表:`fluentwork-backend/.scratch/issues/2026-09-06-W3-backend-tickets/跨仓对应表.md`

## §9 执行顺序与总工时

```
B22 CLOSED 后:
T-I17-1 (0.2d) ──┬──▶ T-I17-2 (0.5d) ──┐
                  ├──▶ T-I17-3 (0.2d) ──┤
                  └──▶ T-I17-4 (0.3d) ──┼──▶ T-I17-5 (0.2d) ──▶ T-I17-6 (0.1d)
```

**总工时**:1.5 dev-day(工作量最大)
**推荐 Owner**:iOS 工程师 C(可选,工作量最大)
**关键路径**:B22 CLOSED 是唯一阻塞;T-I17-2/3/4 可并行开发
