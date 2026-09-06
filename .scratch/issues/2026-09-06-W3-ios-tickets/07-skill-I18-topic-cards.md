# Skill I18 — 话题卡 UI(P1, W4 Day 4, B23 CLOSED 后)

> **Master**: 待建 GitHub Issue `I18: 话题卡 UI(H1/H2/H3)`
> **Sub-tickets**: 5 (T-I18-1..5)
> **总工时**: 1.0 dev-day
> **阻塞**: B23(话题卡生成 backend CLOSED)
> **关联**: I17(复用 SpeakingRoomView), I19

---

## §0 Master Issue Body

**Title**: `I18: 话题卡 UI(H1/H2/H3)`
**Labels**: `ios`, `v2.0`, `priority: P1`, `ui`, `topic`
**Milestone**: `V2.0 W4`

```markdown
## 🎯 目标
实现 PRD §H1/H2/H3 话题卡完整 UI:
- H1 话题卡展示:工作台顶部「今日话题卡」入口 → 列表轮播
- H2 进入对话:点击话题卡 → 跳转 SpeakingRoomView
- H3 聊后打卡:会话结束后打卡弹层 + streak 展示

## 🚧 阻塞条件
- B23(话题卡生成 backend)CLOSED——GET /topic-cards + POST /topic-cards/:id/checkin

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I18-1 | TopicCardModels + TopicCardsClient | 0.2d |
| T-I18-2 | TopicCardCarousel + HomeDashboard 入口 | 0.2d |
| T-I18-3 | TopicCardDetailView | 0.2d |
| T-I18-4 | CheckinSheetView + streak 展示 | 0.3d |
| T-I18-5 | Snapshot测试 + i18n | 0.1d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- REST:fluentwork-meta/docs/30_技术方案/48_FluentWork_V2_REST接口契约冻结_2026-09-06.md §1.7
- SpeakingRoomView 已 live(复用)
```

---

## §1 T-I18-1 — TopicCardModels + TopicCardsClient

**Labels**: `ios`, `v2.0`, `priority: P1`, `topic`, `networking`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现 `TopicCardsClient`,定义话题卡数据模型。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkNetworking/TopicCardsClient.swift`:
   ```swift
   public final class TopicCardsClient {
       private let client: AuthenticatedNetworkClient
       
       public func listToday() async throws -> [TopicCard] {
           try await client.get("/topic-cards")
       }
       
       public func checkin(cardID: String, reflection: String?) async throws -> CheckinResult {
           let body = CheckinRequest(reflection: reflection)
           return try await client.post("/topic-cards/\(cardID)/checkin", body: body)
       }
   }
   
   public struct TopicCard: Codable, Identifiable {
       public let cardID: String
       public let title: String
       public let prompt: String
       public let sceneTag: String
       public let functionTag: String
       public let validUntil: Date
       public var id: String { cardID }
   }
   
   public struct CheckinResult: Codable {
       public let checkinID: String
       public let streakDays: Int
   }
   
   private struct CheckinRequest: Encodable {
       let reflection: String?
   }
   ```
2. 在 `AppDependencies` 注册

## ✅ 验收
- [ ] API 调用编译通过
- [ ] 错误码正确处理

## 🔗 依赖
- Blocked by: B23 CLOSED
- Blocks: T-I18-2, T-I18-3, T-I18-4
- Master: I18
```

---

## §2 T-I18-2 — TopicCardCarousel + HomeDashboard 入口

**Labels**: `ios`, `v2.0`, `priority: P1`, `topic`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
工作台首页添话题卡轮播入口。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Topic/TopicCardCarousel.swift`:
   ```swift
   public struct TopicCardCarousel: View {
       let cards: [TopicCard]
       let onCardTap: (TopicCard) -> Void
       
       public var body: some View {
           VStack(alignment: .leading, spacing: 8) {
               Text("今日话题卡")
                   .font(.headline)
                   .padding(.horizontal)
               ScrollView(.horizontal, showsIndicators: false) {
                   HStack(spacing: 12) {
                       ForEach(cards) { card in
                           Button { onCardTap(card) } label: {
                               TopicCardItem(card: card)
                           }
                           .buttonStyle(.plain)
                       }
                   }
                   .padding(.horizontal)
               }
           }
       }
   }
   
   public struct TopicCardItem: View {
       let card: TopicCard
       public var body: some View {
           VStack(alignment: .leading, spacing: 8) {
               HStack {
                   Text(card.sceneTag)
                       .font(.caption2)
                       .padding(.horizontal, 8).padding(.vertical, 4)
                       .background(Color.blue.opacity(0.15))
                       .clipShape(Capsule())
                   Spacer()
               }
               Text(card.title)
                   .font(.headline)
                   .lineLimit(2)
               Text(card.prompt)
                   .font(.caption)
                   .lineLimit(3)
                   .foregroundStyle(.secondary)
           }
           .frame(width: 220, height: 130, alignment: .topLeading)
           .padding()
           .background(
               LinearGradient(colors: [.blue.opacity(0.08), .purple.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
           )
           .clipShape(RoundedRectangle(cornerRadius: 16))
       }
   }
   ```
2. 在 `AppRootTabView` 的工作台 tab 集成
3. 无话题卡时隐藏该模块

## ✅ 验收
- [ ] T-I18-1 首页加载显示话题卡轮播
- [ ] T-I18-10 无话题卡场景首页隐藏模块
- [ ] 横向滚动流畅

## 🔗 依赖
- Blocked by: T-I18-1
- Blocks: T-I18-5
- Master: I18
```

---

## §3 T-I18-3 — TopicCardDetailView

**Labels**: `ios`, `v2.0`, `priority: P1`, `topic`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
话题卡详情页 + 跳转 SpeakingRoomView。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Topic/TopicCardDetailView.swift`:
   ```swift
   public struct TopicCardDetailView: View {
       let card: TopicCard
       @State private var navigateToSession = false
       
       public var body: some View {
           ScrollView {
               VStack(alignment: .leading, spacing: 16) {
                   Text(card.title)
                       .font(.largeTitle.bold())
                   Text(card.prompt)
                       .font(.title3)
                   HStack {
                       Label(card.sceneTag, systemImage: "tag")
                       Label(card.functionTag, systemImage: "function")
                   }
                   .font(.caption)
                   .foregroundStyle(.secondary)
                   
                   Spacer().frame(height: 32)
                   
                   Button {
                       navigateToSession = true
                   } label: {
                       Label("开始对话练习", systemImage: "play.fill")
                           .frame(maxWidth: .infinity)
                   }
                   .buttonStyle(.borderedProminent)
               }
               .padding()
           }
           .navigationTitle("话题详情")
           .navigationBarTitleDisplayMode(.inline)
           .navigationDestination(isPresented: $navigateToSession) {
               SpeakingRoomView(
                   seedPrompt: card.prompt,
                   topicCardID: card.cardID
               )
           }
       }
   }
   ```
2. `SpeakingRoomView` 新增 `seedPrompt` 和 `topicCardID` 参数
3. 会话结束后触发打卡弹层(`CheckinSheetView`)

## ✅ 验收
- [ ] T-I18-2 点击话题卡 → 跳转详情
- [ ] T-I18-3 点击「开始对话」→ 进入 SpeakingRoom
- [ ] T-I18-8 话题卡过期(validUntil 已过)灰显

## 🔗 依赖
- Blocked by: T-I18-1
- Blocks: T-I18-4, T-I18-5
- Master: I18
```

---

## §4 T-I18-4 — CheckinSheetView + streak 展示

**Labels**: `ios`, `v2.0`, `priority: P1`, `topic`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
聊后打卡弹层 + streak 展示。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Topic/CheckinSheetView.swift`:
   ```swift
   public struct CheckinSheetView: View {
       let cardID: String
       @State private var reflection: String = ""
       @State private var isSubmitting = false
       @State private var streakDays: Int?
       @Environment(\.dismiss) private var dismiss
       
       private let api: TopicCardsClient
       
       public var body: some View {
           NavigationStack {
               VStack(spacing: 20) {
                   Text("完成打卡 🎉").font(.title.bold())
                   
                   if let streak = streakDays {
                       HStack {
                           Image(systemName: streakBadge(streak))
                               .font(.title2)
                           Text("已连续打卡 \(streak) 天")
                               .font(.title2)
                               .foregroundStyle(.orange)
                       }
                   }
                   
                   TextField("今天的复盘…(可选)", text: $reflection, axis: .vertical)
                       .lineLimit(3...6)
                       .padding()
                       .background(Color(.systemGroupedBackground))
                       .clipShape(RoundedRectangle(cornerRadius: 12))
                   
                   Button(action: submit) {
                       if isSubmitting {
                           ProgressView()
                       } else {
                           Text("打卡").frame(maxWidth: .infinity)
                       }
                   }
                   .buttonStyle(.borderedProminent)
               }
               .padding()
               .toolbar {
                   ToolbarItem(placement: .cancellationAction) {
                       Button("跳过") { dismiss() }
                   }
               }
           }
       }
       
       private func submit() {
           Task {
               isSubmitting = true
               let result = try? await api.checkin(cardID: cardID, reflection: reflection.isEmpty ? nil : reflection)
               streakDays = result?.streakDays
               isSubmitting = false
               try? await Task.sleep(nanoseconds: 1_500_000_000)
               dismiss()
           }
       }
       
       private func streakBadge(_ days: Int) -> String {
           if days >= 100 { return "flame.fill" }
           if days >= 30 { return "star.fill" }
           if days >= 7 { return "leaf.fill" }
           return "checkmark.circle.fill"
       }
   }
   ```
2. 在 `SpeakingRoomFeature` 的 session ended 流程中弹出此 sheet
3. streak badge 颜色变化:7 天 → 🍃绿叶,30 天 → ⭐黄星,100 天 → 🔥火焰

## ✅ 验收
- [ ] T-I18-4 会话结束 → 自动弹打卡弹层
- [ ] T-I18-5 打卡 → streak +1 显示
- [ ] T-I18-6 跳过打卡 streak 不变
- [ ] T-I18-7 网络异常 → 错误提示 + 重试
- [ ] T-I18-9 streak badge 颜色变化

## 🔗 依赖
- Blocked by: T-I18-1
- Blocks: T-I18-5
- Master: I18
```

---

## §5 T-I18-5 — Snapshot测试 + i18n

**Labels**: `ios`, `v2.0`, `priority: P1`, `topic`, `testing`, `i18n`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
Snapshot 测试 + i18n。

## 📋 实施步骤
1. 新建 `Tests/FluentWorkCoreTests/TopicCardViewSnapshotTests.swift`:
   - testTopicCardCarousel
   - testTopicCardItem
   - testTopicCardDetailView
   - testCheckinSheetView_Success
   - testCheckinSheetView_Skip
2. i18n:所有用户可见字符串支持中英

## ✅ 验收
- [ ] 5 个 Snapshot PASS
- [ ] T-I18-11 VoiceOver 每张卡片可朗读
- [ ] i18n 切换语言正常

## 🔗 依赖
- Blocked by: T-I18-2, T-I18-3, T-I18-4
- Blocks: 无(Master 收口)
- Master: I18
```

---

## §6 执行顺序与总工时

```
B23 CLOSED 后:
T-I18-1 (0.2d) ──┬──▶ T-I18-2 (0.2d) ──┐
                  ├──▶ T-I18-3 (0.2d) ──┤
                  └──▶ T-I18-4 (0.3d) ──┴──▶ T-I18-5 (0.1d)
```

**总工时**:1.0 dev-day
**推荐 Owner**:iOS 工程师 B
**关键路径**:B23 CLOSED 是唯一阻塞;T-I18-2/3/4 可并行
