# Skill I14 — 创建练习弹层(P1, W4 Day 1, B21 CLOSED 后)

> **Master**: 待建 GitHub Issue `I14: 创建练习弹层(A1/A2)`
> **Sub-tickets**: 4 (T-I14-1..4)
> **总工时**: 1.0 dev-day
> **阻塞**: B21(素材模块 backend CLOSED)
> **关联**: I25(语料库详情,V1.5)

---

## §0 Master Issue Body

**Title**: `I14: 创建练习弹层(A1/A2)`
**Labels**: `ios`, `v2.0`, `priority: P1`, `ui`, `materials`
**Milestone**: `V2.0 W4`

```markdown
## 🎯 目标
实现 PRD §A1/A2 创建练习入口:
- 用户粘贴英文文本 / 一句话 / URL → POST 创建 material
- 提交后「提炼中」loading(轮询 GET /materials/:id)
- 提炼完成跳转语料库详情页(占位)

## 🚧 阻塞条件
- B21(素材模块 backend)CLOSED——POST /api/v1/materials + GET /api/v1/materials/:id

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I14-1 | MaterialsAPIClient 实现 | 0.2d |
| T-I14-2 | CreatePracticeView + Picker | 0.3d |
| T-I14-3 | CreatePracticeViewModel + 轮询逻辑 | 0.3d |
| T-I14-4 | Loading/Error/Ready UI + Snapshot | 0.2d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- REST:fluentwork-meta/docs/30_技术方案/48_FluentWork_V2_REST接口契约冻结_2026-09-06.md §1.2
- I25:语料库详情(V1.5,占位跳转)
```

---

## §1 T-I14-1 — MaterialsAPIClient 实现

**Labels**: `ios`, `v2.0`, `priority: P1`, `materials`, `networking`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现 `MaterialsAPIClient` 的 createMaterial + getMaterial 方法。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkNetworking/MaterialsAPIClient.swift`:
   ```swift
   public final class MaterialsAPIClient {
       private let client: AuthenticatedNetworkClient
       
       public func createMaterial(kind: MaterialKind, content: String) async throws -> String {
           let body = CreateMaterialRequest(kind: kind.rawValue, content: content)
           let response: CreateMaterialResponse = try await client.post(
               "/materials",
               body: body
           )
           return response.materialID
       }
       
       public func getMaterial(id: String) async throws -> MaterialDetail {
           try await client.get("/materials/\(id)")
       }
   }
   
   enum MaterialKind: String, Codable { case text, voiceNote, url }
   struct CreateMaterialRequest: Encodable { let kind: String; let content: String }
   struct CreateMaterialResponse: Decodable { let materialID: String; let refineStatus: String }
   struct MaterialDetail: Decodable {
       let id: String; let refineStatus: String; let title: String?; let error: String?
   }
   ```
2. 在 `AppDependencies` 注册 MaterialsAPIClient

## ✅ 验收
- [ ] API 调用编译通过
- [ ] 401/404/422 错误码正确处理
- [ ] Retry 逻辑(5xx 重试 1 次)

## 🔗 依赖
- Blocked by: B21 CLOSED
- Blocks: T-I14-2, T-I14-3
- Master: I14
```

---

## §2 T-I14-2 — CreatePracticeView + Picker

**Labels**: `ios`, `v2.0`, `priority: P1`, `ui`, `materials`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现 `CreatePracticeView` UI + kind Picker + TextEditor。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Materials/CreatePracticeView.swift`:
   ```swift
   public struct CreatePracticeView: View {
       @StateObject private var viewModel: CreatePracticeViewModel
       @Environment(\.dismiss) private var dismiss
       
       public init(viewModel: CreatePracticeViewModel) {
           _viewModel = StateObject(wrappedValue: viewModel)
       }
       
       public var body: some View {
           NavigationStack {
               VStack(spacing: 16) {
                   Picker("类型", selection: $viewModel.inputKind) {
                       Text("粘贴文本").tag(MaterialKind.text)
                       Text("一句话").tag(MaterialKind.voiceNote)
                       Text("URL").tag(MaterialKind.url)
                   }
                   .pickerStyle(.segmented)
                   
                   TextEditor(text: $viewModel.inputText)
                       .frame(minHeight: 120)
                   
                   Button("开始提炼") {
                       Task { await viewModel.submit() }
                   }
                   .buttonStyle(.borderedProminent)
                   .disabled(viewModel.inputText.isEmpty || viewModel.isSubmitting)
               }
               .padding()
               .navigationTitle("新建练习")
               .navigationBarTitleDisplayMode(.inline)
           }
       }
   }
   ```
2. 入口:从工作台 FAB 或设置入口弹出(sheet 形式)
3. 支持 swipe down dismiss,但草稿保留(二次确认)

## ✅ 验收
- [ ] 3 种 kind 切换正常
- [ ] TextEditor placeholder 正确
- [ ] 空输入提交按钮 disabled

## 🔗 依赖
- Blocked by: T-I14-1
- Blocks: T-I14-4
- Master: I14
```

---

## §3 T-I14-3 — CreatePracticeViewModel + 轮询逻辑

**Labels**: `ios`, `v2.0`, `priority: P1`, `ui`, `materials`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现 `CreatePracticeViewModel`,包含提交 + 轮询 + 跳转逻辑。

## 📋 实施步骤
1. 新建 `CreatePracticeViewModel.swift`:
   ```swift
   @MainActor
   public final class CreatePracticeViewModel: ObservableObject {
       @Published var inputText: String = ""
       @Published var inputKind: MaterialKind = .text
       @Published var isSubmitting = false
       @Published var refineStatus: RefineStatus = .idle
       @Published var error: Error?
       @Published var submittedMaterialID: String?
       
       enum RefineStatus: Equatable {
           case idle, queued, processing, ready, failed
       }
       
       private let api: MaterialsAPIClient
       private var pollTask: Task<Void, Never>?
       private let onReady: (String) -> Void
       
       func submit() async {
           isSubmitting = true
           defer { isSubmitting = false }
           do {
               let materialID = try await api.createMaterial(kind: inputKind, content: inputText)
               submittedMaterialID = materialID
               refineStatus = .queued
               startPolling(materialID: materialID)
           } catch {
               self.error = error
           }
       }
       
       private func startPolling(materialID: String) {
           pollTask?.cancel()
           pollTask = Task {
               while !Task.isCancelled {
                   try? await Task.sleep(nanoseconds: 2_000_000_000)
                   if Task.isCancelled { return }
                   let mat = try? await api.getMaterial(id: materialID)
                   guard let m = mat else { continue }
                   await MainActor.run {
                       refineStatus = RefineStatus(rawValue: m.refineStatus) ?? .processing
                       if m.refineStatus == "ready" {
                           onReady(materialID)
                       } else if m.refineStatus == "failed" {
                           error = NSError(domain: "refine", code: -1, userInfo: [NSLocalizedDescriptionKey: m.error ?? "提炼失败"])
                       }
                   }
                   if m.refineStatus == "ready" || m.refineStatus == "failed" { return }
               }
           }
       }
   }
   ```
2. `onReady` 回调触发导航到语料库详情页(占位)

## ✅ 验收
- [ ] 提交后进入轮询状态
- [ ] 2s 轮询间隔正确
- [ ] ready 后触发 onReady 回调
- [ ] T-I14-7 提炼中再次提交被拒绝

## 🔗 依赖
- Blocked by: T-I14-1
- Blocks: T-I14-4
- Master: I14
```

---

## §4 T-I14-4 — Loading/Error/Ready UI + Snapshot

**Labels**: `ios`, `v2.0`, `priority: P1`, `ui`, `materials`, `testing`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
完善 Loading/Error/Ready 各状态的 UI + Snapshot 测试。

## 📋 实施步骤
1. 在 `CreatePracticeView` 添加各状态 UI:
   ```swift
   // refineStatus == .queued / .processing
   VStack {
       ProgressView()
       Text("AI 正在提炼话术，预计 10-15 秒")
   }
   
   // refineStatus == .ready
   VStack {
       Image(systemName: "checkmark.circle.fill")
           .font(.largeTitle).foregroundStyle(.green)
       Text("提炼完成!")
       Button("查看详情") { /* 跳转 */ }
   }
   
   // refineStatus == .failed
   VStack {
       Text("提炼失败，请重试").foregroundStyle(.red)
       Button("重试") { Task { await viewModel.submit() } }
   }
   ```
2. 二次确认:dismiss 前检测有草稿内容,弹 alert
3. 新建 `Tests/FluentWorkCoreTests/CreatePracticeViewSnapshotTests.swift`

## ✅ 验收
- [ ] T-I14-1 粘贴 200 词 → loading → ready → 跳转
- [ ] T-I14-5 后端 5xx → 错误提示 + 重试按钮
- [ ] T-I14-6 dismiss 二次确认
- [ ] T-I14-8 rate_limited 错误码显示
- [ ] T-I14-9 VoiceOver TextEditor 可操作
- [ ] T-I14-10 离线状态不发送请求
- [ ] 4 个 Snapshot 测试 PASS

## 🔗 依赖
- Blocked by: T-I14-2, T-I14-3
- Blocks: 无(Master 收口)
- Master: I14
```

---

## §5 执行顺序与总工时

```
B21 CLOSED 后:
T-I14-1 (0.2d) ──┬──▶ T-I14-2 (0.3d) ──┐
                  └──▶ T-I14-3 (0.3d) ──┴──▶ T-I14-4 (0.2d)
```

**总工时**:1.0 dev-day
**推荐 Owner**:iOS 工程师 B
**关键路径**:B21 CLOSED 是唯一阻塞;T-I14-2 和 T-I14-3 可并行开发
