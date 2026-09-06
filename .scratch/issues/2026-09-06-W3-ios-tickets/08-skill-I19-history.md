# Skill I19 — 历史回顾列表(P2, W4 Day 5, B24 CLOSED 后)

> **Master**: 待建 GitHub Issue `I19: 历史回顾列表(C4)`
> **Sub-tickets**: 4 (T-I19-1..4)
> **总工时**: 0.5 dev-day
> **阻塞**: B24(历史回顾 API CLOSED)
> **关联**: I16(复用 SessionReviewView), 32_ §十

---

## §0 Master Issue Body

**Title**: `I19: 历史回顾列表(C4)`
**Labels**: `ios`, `v2.0`, `priority: P2`, `ui`, `sessions`
**Milestone**: `V2.0 W4`

```markdown
## 🎯 目标
实现 PRD §C4 历史回顾列表:
- 工作台新增「历史回顾」入口
- 列表展示用户过去 30 天会话(cursor 分页)
- 点击进入会话详情(复用 I16 SessionReviewView)

## 🚧 阻塞条件
- B24(历史回顾 API)CLOSED——GET /sessions 支持 cursor 分页

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I19-1 | SessionListModels + SessionAPIClient.listSessions | 0.1d |
| T-I19-2 | SessionListViewModel + cursor 分页 | 0.2d |
| T-I19-3 | SessionListView + StatusBadge + HomeDashboard 入口 | 0.1d |
| T-I19-4 | Snapshot测试 | 0.1d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- REST:fluentwork-meta/docs/30_技术方案/48_FluentWork_V2_REST接口契约冻结_2026-09-06.md §1.3.2
- I16 SessionReviewView(复用)
```

---

## §1 T-I19-1 — SessionListModels + listSessions

**Labels**: `ios`, `v2.0`, `priority: P2`, `sessions`, `networking`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
扩展 `SessionAPIClient`,实现 `listSessions` cursor 分页方法。

## 📋 实施步骤
1. 在 `Shared/FluentWorkNetworking/SessionAPIClient.swift` 添加:
   ```swift
   public func listSessions(cursor: String? = nil, size: Int = 20) async throws -> SessionListPage {
       var path = "/sessions?size=\(size)"
       if let cursor = cursor { path += "&cursor=\(cursor)" }
       return try await client.get(path)
   }
   
   public struct SessionListPage: Decodable {
       public let items: [SessionListItem]
       public let nextCursor: String?
   }
   
   public struct SessionListItem: Codable, Identifiable {
       public let sessionID: String
       public let materialIDs: [String]
       public let reviewStatus: String
       public let startedAt: Date
       public let endedAt: Date?
       public var id: String { sessionID }
   }
   ```

## ✅ 验收
- [ ] API 调用编译通过
- [ ] cursor 参数正确传递

## 🔗 依赖
- Blocked by: B24 CLOSED
- Blocks: T-I19-2, T-I19-3
- Master: I19
```

---

## §2 T-I19-2 — SessionListViewModel + cursor 分页

**Labels**: `ios`, `v2.0`, `priority: P2`, `sessions`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现 `SessionListViewModel`,支持 cursor 分页加载。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/History/SessionListViewModel.swift`:
   ```swift
   @MainActor
   public final class SessionListViewModel: ObservableObject {
       @Published public var items: [SessionListItem] = []
       @Published public var nextCursor: String?
       @Published public var isLoading = false
       @Published public var error: Error?
       
       private let api: SessionAPIClient
       
       public func loadInitial() async {
           items = []
           nextCursor = nil
           await loadMore()
       }
       
       public func loadMore() async {
           guard !isLoading else { return }
           isLoading = true
           defer { isLoading = false }
           do {
               let page = try await api.listSessions(cursor: nextCursor)
               items.append(contentsOf: page.items)
               nextCursor = page.nextCursor
           } catch {
               self.error = error
           }
       }
   }
   ```

## ✅ 验收
- [ ] T-I19-1 加载 20 条 session
- [ ] T-I19-2 滚动到底 → 自动加载下一页
- [ ] 最后一页 cursor=nil 不再请求

## 🔗 依赖
- Blocked by: T-I19-1
- Blocks: T-I19-3
- Master: I19
```

---

## §3 T-I19-3 — SessionListView + StatusBadge + HomeDashboard 入口

**Labels**: `ios`, `v2.0`, `priority: P2`, `sessions`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现会话列表 View + StatusBadge + 工作台入口。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/History/SessionListView.swift`:
   ```swift
   public struct SessionListView: View {
       @StateObject private var viewModel: SessionListViewModel
       
       public init(viewModel: SessionListViewModel) {
           _viewModel = StateObject(wrappedValue: viewModel)
       }
       
       public var body: some View {
           List {
               ForEach(viewModel.items) { item in
                   NavigationLink {
                       SessionReviewView(sessionID: item.sessionID)  // I16 复用
                   } label: {
                       SessionRow(item: item)
                   }
                   .onAppear {
                       if item == viewModel.items.last {
                           Task { await viewModel.loadMore() }
                       }
                   }
               }
               if viewModel.isLoading {
                   ProgressView().frame(maxWidth: .infinity)
               }
           }
           .navigationTitle("历史回顾")
           .task { await viewModel.loadInitial() }
       }
   }
   
   public struct SessionRow: View {
       let item: SessionListItem
       public var body: some View {
           HStack {
               VStack(alignment: .leading) {
                   Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                       .font(.headline)
                   Text("素材 \(item.materialIDs.count) 个")
                       .font(.caption)
                       .foregroundStyle(.secondary)
               }
               Spacer()
               StatusBadge(status: item.reviewStatus)
           }
       }
   }
   
   public struct StatusBadge: View {
       let status: String
       private var color: Color {
           switch status { case "ready": return .green; case "failed": return .red; default: return .orange }
       }
       public var body: some View {
           Text(status)
               .font(.caption)
               .padding(.horizontal, 8).padding(.vertical, 4)
               .background(color.opacity(0.15))
               .foregroundStyle(color)
               .clipShape(Capsule())
       }
   }
   ```
2. 在 `AppRootTabView` 添加历史回顾 tab 入口
3. 空列表时显示引导文案

## ✅ 验收
- [ ] T-I19-3 点击 session → 跳转详情(I16)
- [ ] T-I19-4 空列表引导文案
- [ ] T-I19-5 网络异常重试按钮
- [ ] T-I19-6/7 review_status badge 颜色正确

## 🔗 依赖
- Blocked by: T-I19-2
- Blocks: T-I19-4
- Master: I19
```

---

## §4 T-I19-4 — Snapshot测试

**Labels**: `ios`, `v2.0`, `priority: P2`, `sessions`, `testing`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
完整 Snapshot 测试。

## 📋 实施步骤
1. 新建 `Tests/FluentWorkCoreTests/SessionListViewSnapshotTests.swift`:
   - testSessionListView_WithData
   - testSessionListView_Empty
   - testSessionListView_Error
   - testSessionRow_Ready
   - testSessionRow_Pending
   - testSessionRow_Failed
2. VoiceOver:列表项可朗读

## ✅ 验收
- [ ] 6 个 Snapshot PASS
- [ ] T-I19-10 VoiceOver 通过

## 🔗 依赖
- Blocked by: T-I19-3
- Blocks: 无(Master 收口)
- Master: I19
```

---

## §5 执行顺序与总工时

```
B24 CLOSED 后:
T-I19-1 (0.1d) ──▶ T-I19-2 (0.2d) ──▶ T-I19-3 (0.1d) ──▶ T-I19-4 (0.1d)
```

**总工时**:0.5 dev-day(工作量最小)
**推荐 Owner**:iOS 工程师 A
**关键路径**:B24 CLOSED 是唯一阻塞
