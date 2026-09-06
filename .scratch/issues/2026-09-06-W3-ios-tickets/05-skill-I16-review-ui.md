# Skill I16 — 完整转录浮层(P1, W4 Day 2, B18 CLOSED 后)

> **Master**: 待建 GitHub Issue `I16: 完整转录浮层(C1 增强)`
> **Sub-tickets**: 4 (T-I16-1..4)
> **总工时**: 1.0 dev-day
> **阻塞**: B18(review eval CLOSED)
> **关联**: I19(复用 SessionReviewView), 46 V1.2 §B4

---

## §0 Master Issue Body

**Title**: `I16: 完整转录浮层(C1 增强)`
**Labels**: `ios`, `v2.0`, `priority: P1`, `ui`, `review`
**Milestone**: `V2.0 W4`

```markdown
## 🎯 目标
PRD C1 增强:完整话轮展示 + 录音回听 + AI 评价 3 维可视化。

## 🚧 阻塞条件
- B18(review eval 真实 LLM 接入)CLOSED——GET /sessions/:id/review 返回 eval 字段

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I16-1 | SessionReviewViewModel 增强 | 0.3d |
| T-I16-2 | UtteranceRow + 播放逻辑 | 0.3d |
| T-I16-3 | EvalCard 3维可视化 | 0.2d |
| T-I16-4 | Snapshot测试 + 错误态 | 0.2d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- REST:fluentwork-meta/docs/30_技术方案/48_FluentWork_V2_REST接口契约冻结_2026-09-06.md §1.3.7
- I19 复用:SessionReviewView(共 view)
```

---

## §1 T-I16-1 — SessionReviewViewModel 增强

**Labels**: `ios`, `v2.0`, `priority: P1`, `review`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
增强 `SessionReviewViewModel`,加载 review + eval 数据。

## 📋 实施步骤
1. 修改 `Shared/FluentWorkCore/Architecture/Features/ReviewFeature.swift`:
   ```swift
   @MainActor
   public final class SessionReviewViewModel: ObservableObject {
       @Published public var utterances: [UtteranceItem] = []
       @Published public var eval: EvalSummary?
       @Published public var audioPlaybackState: AudioPlaybackState = .idle
       @Published public var error: Error?
       
       private let sessionAPI: SessionAPIClient
       private let currentSessionID: String
       
       public func load() async {
           do {
               let review = try await sessionAPI.getReview(sessionID: currentSessionID)
               utterances = review.utterances
               eval = review.eval
           } catch {
               self.error = error
           }
       }
       
       public func playAudio(utteranceID: String) async {
           audioPlaybackState = .loading
           do {
               let audioURL = try await sessionAPI.getAudioURL(sessionID: currentSessionID, utteranceID: utteranceID)
               audioPlaybackState = .playing(url: audioURL)
               // TODO: 接入 AudioPlayer
           } catch {
               audioPlaybackState = .error(error)
           }
       }
   }
   
   public struct UtteranceItem: Codable, Identifiable {
       public let id: String
       public let speaker: String
       public let text: String
       public let audioURL: String?
       public let startedAtMs: Int64
       public let endedAtMs: Int64
   }
   
   public struct EvalSummary: Codable {
       public let score: Double
       public let dims: [String: Double]
       public let suggestions: [String]
   }
   ```

## ✅ 验收
- [ ] 编译通过,API 模型正确
- [ ] review.pending 状态正确处理

## 🔗 依赖
- Blocked by: B18 CLOSED
- Blocks: T-I16-2, T-I16-3
- Master: I16
```

---

## §2 T-I16-2 — UtteranceRow + 播放逻辑

**Labels**: `ios`, `v2.0`, `priority: P1`, `review`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现 `UtteranceRow` UI(区分 AI/User 气泡 + 播放按钮)。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Review/UtteranceRow.swift`:
   ```swift
   public struct UtteranceRow: View {
       let utterance: UtteranceItem
       let onPlayAudio: () -> Void
       
       public var body: some View {
           HStack(alignment: .bottom, spacing: 8) {
               if utterance.speaker == "user" {
                   Spacer(minLength: 60)
               }
               
               VStack(alignment: utterance.speaker == "ai" ? .leading : .trailing, spacing: 4) {
                   Text(utterance.text)
                       .font(.body)
                       .padding(12)
                       .background(utterance.speaker == "ai"
                           ? Color.blue.opacity(0.1)
                           : Color(.systemBackground))
                       .clipShape(RoundedRectangle(cornerRadius: 16))
                   
                   if utterance.speaker == "user", utterance.audioURL != nil {
                       Button(action: onPlayAudio) {
                           Image(systemName: "play.circle.fill")
                               .font(.title2)
                               .foregroundStyle(.blue)
                       }
                       .transition(.scale.combined(with: .opacity))
                   }
               }
               
               if utterance.speaker == "ai" {
                   Spacer(minLength: 60)
               }
           }
       }
   }
   ```
2. 在 `SessionReviewView` 中渲染 `ForEach(viewModel.utterances) { UtteranceRow(utterance: $0) }`
3. 播放中切换 utterance 自动停止上一段

## ✅ 验收
- [ ] T-I16-1 加载完整会话 review
- [ ] T-I16-2 点击播放按钮 → 音频加载 → 播放
- [ ] T-I16-3 播放中切换 utterance 自动停止
- [ ] T-I16-4 AI utterance 不显示播放按钮

## 🔗 依赖
- Blocked by: T-I16-1
- Blocks: T-I16-4
- Master: I16
```

---

## §3 T-I16-3 — EvalCard 3维可视化

**Labels**: `ios`, `v2.0`, `priority: P1`, `review`, `ui`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
实现 `EvalCard`,展示 3 维评分(score + 3 dims + suggestions)。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Features/Review/EvalCard.swift`:
   ```swift
   public struct EvalCard: View {
       let eval: EvalSummary
       
       public var body: some View {
           VStack(alignment: .leading, spacing: 12) {
               HStack {
                   Text("总评").font(.headline)
                   Spacer()
                   Text("\(Int(eval.score * 100))分")
                       .font(.title2.bold())
                       .foregroundStyle(scoreColor)
               }
               
               ForEach(eval.dims.sorted(by: { $0.key < $1.key }), id: \.key) { dim in
                   HStack {
                       Text(dimLabel(dim.key))
                           .font(.caption)
                           .frame(width: 60, alignment: .leading)
                       ProgressView(value: dim.value)
                           .tint(dimColor(dim.value))
                       Text("\(Int(dim.value * 100))%")
                           .font(.caption)
                           .frame(width: 40, alignment: .trailing)
                   }
               }
               
               if !eval.suggestions.isEmpty {
                   Divider()
                   Text("改进建议").font(.subheadline.bold())
                   ForEach(eval.suggestions, id: \.self) { s in
                       HStack(alignment: .top) {
                           Image(systemName: "lightbulb.fill")
                               .font(.caption)
                               .foregroundStyle(.yellow)
                           Text(s)
                               .font(.caption)
                       }
                   }
               }
           }
           .padding()
           .background(Color(.systemGroupedBackground))
           .clipShape(RoundedRectangle(cornerRadius: 12))
       }
       
       private var scoreColor: Color {
           eval.score >= 0.8 ? .green : eval.score >= 0.6 ? .orange : .red
       }
       
       private func dimColor(_ value: Double) -> Color {
           value >= 0.8 ? .green : value >= 0.6 ? .orange : .red
       }
       
       private func dimLabel(_ key: String) -> String {
           switch key { case "grammar": return "语法"
           case "fluency": return "流利度"
           case "vocabulary": return "词汇"
           default: return key }
       }
   }
   ```
2. 无 eval 时(`eval == nil`):显示「正在生成评价...」+ 1s 后重试

## ✅ 验收
- [ ] T-I16-5 评价 3 维展示正确
- [ ] T-I16-6 suggestions 列表渲染
- [ ] T-I16-7 score < 60 红色提示
- [ ] T-I16-10 无 eval 显示「正在生成评价...」

## 🔗 依赖
- Blocked by: T-I16-1
- Blocks: T-I16-4
- Master: I16
```

---

## §4 T-I16-4 — Snapshot测试 + 错误态

**Labels**: `ios`, `v2.0`, `priority: P1`, `review`, `testing`
**Milestone**: `V2.0 W4`

### Body

```markdown
## 🎯 目标
完整 Snapshot 测试 + 错误态处理。

## 📋 实施步骤
1. 新建 `Tests/FluentWorkCoreTests/SessionReviewViewSnapshotTests.swift`:
   - testUtteranceRow_UserWithAudio
   - testUtteranceRow_AI
   - testEvalCard_HighScore
   - testEvalCard_LowScore
   - testEvalCard_NoSuggestions
   - testSessionReviewView_LongSession(50 utterances)
2. 错误态处理:
   - 音频 404:显示「录音已过期」+ 不崩溃
   - 网络失败:显示错误 + 重试按钮
   - review.pending:显示「正在生成评价...」

## ✅ 验收
- [ ] 5 个 Snapshot 测试 PASS
- [ ] T-I16-8 录音回听失败正确处理
- [ ] T-I16-9 长会话 LazyVStack 流畅

## 🔗 依赖
- Blocked by: T-I16-2, T-I16-3
- Blocks: 无(Master 收口)
- Master: I16
```

---

## §5 执行顺序与总工时

```
B18 CLOSED 后:
T-I16-1 (0.3d) ──┬──▶ T-I16-2 (0.3d) ──┐
                  └──▶ T-I16-3 (0.2d) ──┴──▶ T-I16-4 (0.2d)
```

**总工时**:1.0 dev-day
**推荐 Owner**:iOS 工程师 A
**关键路径**:B18 CLOSED 是唯一阻塞;T-I16-2 和 T-I16-3 可并行
