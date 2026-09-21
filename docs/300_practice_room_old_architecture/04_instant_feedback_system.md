# 即时反馈系统设计

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 4  
**状态**: 设计阶段

---

## 一、设计目标

即时反馈系统是 FluentWork 的核心护城河之一，负责实时检测用户是否用上已练习的话术块，并在当轮对话内给予轻量正反馈。

**关键原则**（PRD §2.2 第一性原理）:
> 即时强化的时效性决定习得效率。用户在对话中用上了练过的表达，反馈必须在当轮对话内到达。

**技术指标**:
- 检测延迟 ≤ 500ms（不阻塞 TTS）
- 误命中率 < 5%（宁可漏报不可错报）
- 命中置信度阈值 ≥ 0.85
- 并行检测不影响对话流畅度

---

## 二、系统架构

### 2.1 整体架构

```
用户话轮完成
    ↓
┌───────────────────────────────────────┐
│  InstantFeedbackDetector (Actor)      │
│                                        │
│  ┌──────────────────────────────────┐ │
│  │  1. 获取用户转录文本              │ │
│  └──────────────────────────────────┘ │
│           ↓                            │
│  ┌──────────────────────────────────┐ │
│  │  2. 并行检测所有活跃话术块        │ │
│  │     (语义匹配 API 调用)           │ │
│  └──────────────────────────────────┘ │
│           ↓                            │
│  ┌──────────────────────────────────┐ │
│  │  3. 过滤低置信度匹配              │ │
│  │     (阈值 ≥ 0.85)                 │ │
│  └──────────────────────────────────┘ │
│           ↓                            │
│  ┌──────────────────────────────────┐ │
│  │  4. 语义等价二次验证              │ │
│  └──────────────────────────────────┘ │
│           ↓                            │
│  ┌──────────────────────────────────┐ │
│  │  5. 返回命中结果                  │ │
│  └──────────────────────────────────┘ │
└───────────────────────────────────────┘
    ↓
PracticeRoomService 处理命中
    ↓
┌─────────────────────────┬─────────────────────────┐
│  记录实战使用次数        │  触发 UI 徽章动画        │
│  (PhraseBlockManager)   │  (ViewModel)            │
└─────────────────────────┴─────────────────────────┘
    ↓
通知 AI（在下一轮自然确认）
```

### 2.2 并发模型

```
对话主流 (不可阻塞)               即时反馈检测 (并行)
────────────────────────         ──────────────────────
用户说话结束                       ↑
  ↓                               │
ASR 转录完成 ────────────────────→ 启动检测 (Task.detached)
  ↓                               │
LLM 开始生成                       │ (并行执行)
  ↓                               │ API 调用
TTS 开始播放 ←───────────────────── 检测完成 (≤500ms)
  ↓                               ↓
AI 说话                          徽章展示
```

**关键设计**:
- 检测在独立 Task 中运行，不阻塞主对话流
- 使用 `Task.detached(priority: .userInitiated)` 确保优先级
- 检测结果通过 AsyncStream 异步通知
- 即使检测失败也不影响对话继续

---

## 三、核心实现

### 3.1 InstantFeedbackDetector

```swift
actor InstantFeedbackDetector {
    // MARK: - Dependencies
    
    private let apiService: PracticeRoomAPIService
    private let semanticMatcher: SemanticMatcher
    
    // MARK: - Configuration
    
    private let confidenceThreshold: Double = 0.85  // 保守阈值
    private let maxConcurrentChecks = 10  // 限制并发数
    private let detectionTimeout: TimeInterval = 0.5  // 500ms 超时
    
    // MARK: - State
    
    private var sessionID: UUID?
    private var activePhraseBlocks: [PhraseBlock] = []
    private var isMonitoring = false
    
    // MARK: - Lifecycle
    
    func startMonitoring(sessionID: UUID, phraseBlocks: [PhraseBlock]) {
        self.sessionID = sessionID
        self.activePhraseBlocks = phraseBlocks
        self.isMonitoring = true
        
        Logger.info("Started instant feedback monitoring with \(phraseBlocks.count) phrase blocks")
    }
    
    func stopMonitoring() {
        isMonitoring = false
        sessionID = nil
        activePhraseBlocks = []
        
        Logger.info("Stopped instant feedback monitoring")
    }
    
    // MARK: - Detection
    
    func detectMatches(userText: String) async -> [PhraseMatch]? {
        guard isMonitoring, !activePhraseBlocks.isEmpty else {
            return nil
        }
        
        let startTime = Date()
        
        do {
            // 调用后端匹配服务（批量匹配）
            let matches = try await withTimeout(detectionTimeout) {
                try await apiService.matchPhraseBlocks(
                    userText: userText,
                    phraseBlocks: activePhraseBlocks
                )
            }
            
            // 过滤与验证
            let validatedMatches = await validateMatches(matches, userText: userText)
            
            // 监控延迟
            let elapsed = Date().timeIntervalSince(startTime)
            await recordLatency(elapsed)
            
            if elapsed > detectionTimeout {
                Logger.warning("Match detection took \(elapsed * 1000)ms, exceeds 500ms target")
            }
            
            return validatedMatches.isEmpty ? nil : validatedMatches
            
        } catch {
            Logger.error("Match detection failed: \(error)")
            // 检测失败不影响对话
            return nil
        }
    }
    
    // MARK: - Validation
    
    private func validateMatches(
        _ matches: [PhraseMatch],
        userText: String
    ) async -> [PhraseMatch] {
        var validated: [PhraseMatch] = []
        
        for match in matches {
            // 第一层：置信度过滤
            guard match.confidence >= confidenceThreshold else {
                Logger.debug("Match filtered by confidence: \(match.confidence) < \(confidenceThreshold)")
                continue
            }
            
            // 第二层：语义等价验证
            guard match.semanticEquivalence else {
                Logger.debug("Match filtered by semantic equivalence check")
                continue
            }
            
            // 第三层：防止重复命中（同一个话术块在本轮对话中只命中一次）
            guard !hasRecentlyMatched(phraseBlockID: match.phraseBlockID) else {
                Logger.debug("Match filtered: recently matched in this session")
                continue
            }
            
            validated.append(match)
        }
        
        return validated
    }
    
    private func hasRecentlyMatched(phraseBlockID: UUID) -> Bool {
        // TODO: 维护最近命中记录，防止同一会话重复命中
        false
    }
    
    // MARK: - Metrics
    
    private func recordLatency(_ latency: TimeInterval) async {
        // TODO: 上报延迟监控
    }
    
    // MARK: - Timeout Helper
    
    private func withTimeout<T>(
        _ timeout: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw FeedbackError.detectionTimeout
            }
            
            guard let result = try await group.next() else {
                throw FeedbackError.detectionTimeout
            }
            
            group.cancelAll()
            return result
        }
    }
}

enum FeedbackError: Error {
    case detectionTimeout
    case apiCallFailed
}
```

### 3.2 语义匹配策略

**双重验证机制**:

1. **粗筛（快速）**: Sentence Embedding 相似度
2. **精筛（准确）**: LLM 语义等价判定

```swift
protocol SemanticMatcher {
    func computeSimilarity(_ text1: String, _ text2: String) async -> Double
    func isSemanticEquivalent(_ text1: String, _ text2: String) async -> Bool
}

actor HybridSemanticMatcher: SemanticMatcher {
    private let embeddingService: EmbeddingService
    private let llmService: LLMService
    
    private let embeddingThreshold: Double = 0.75  // 粗筛阈值
    
    func computeSimilarity(_ text1: String, _ text2: String) async -> Double {
        // 使用 sentence embeddings 计算余弦相似度
        let embedding1 = await embeddingService.getEmbedding(text1)
        let embedding2 = await embeddingService.getEmbedding(text2)
        
        return cosineSimilarity(embedding1, embedding2)
    }
    
    func isSemanticEquivalent(_ text1: String, _ text2: String) async -> Bool {
        // 第一步：embedding 粗筛
        let similarity = await computeSimilarity(text1, text2)
        guard similarity >= embeddingThreshold else {
            return false
        }
        
        // 第二步：LLM 精筛（只对高相似度的候选进行）
        return await llmSemanticCheck(text1, text2)
    }
    
    private func llmSemanticCheck(_ text1: String, _ text2: String) async -> Bool {
        let prompt = """
        Compare these two English sentences and determine if they express the same meaning:
        
        Sentence 1: "\(text1)"
        Sentence 2: "\(text2)"
        
        Consider:
        - Different word choices for the same concept (e.g., "crucial" vs "critical")
        - Different sentence structures expressing the same idea
        - Synonyms and paraphrasing
        
        Respond with only "YES" or "NO".
        """
        
        do {
            let response = try await llmService.complete(prompt: prompt)
            return response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"
        } catch {
            Logger.error("LLM semantic check failed: \(error)")
            // 降级：失败时保守判定为不等价
            return false
        }
    }
    
    private func cosineSimilarity(_ vec1: [Float], _ vec2: [Float]) -> Double {
        guard vec1.count == vec2.count else { return 0.0 }
        
        let dotProduct = zip(vec1, vec2).map(*).reduce(0, +)
        let magnitude1 = sqrt(vec1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(vec2.map { $0 * $0 }.reduce(0, +))
        
        guard magnitude1 > 0, magnitude2 > 0 else { return 0.0 }
        
        return Double(dotProduct / (magnitude1 * magnitude2))
    }
}
```

### 3.3 本地 Embedding 优化（可选）

为进一步降低延迟，可使用 Core ML 本地模型：

```swift
actor LocalEmbeddingService: EmbeddingService {
    private var model: MLModel?
    
    init() {
        loadModel()
    }
    
    private func loadModel() {
        // 加载预训练的 Sentence Transformer 模型（如 all-MiniLM-L6-v2）
        guard let modelURL = Bundle.main.url(forResource: "sentence_transformer", withExtension: "mlmodelc") else {
            Logger.error("Embedding model not found")
            return
        }
        
        do {
            model = try MLModel(contentsOf: modelURL)
        } catch {
            Logger.error("Failed to load embedding model: \(error)")
        }
    }
    
    func getEmbedding(_ text: String) async -> [Float] {
        guard let model = model else {
            // 降级到远程服务
            return await fallbackToRemoteEmbedding(text)
        }
        
        do {
            // 分词与编码
            let tokens = tokenize(text)
            let input = prepareInput(tokens)
            
            // 推理
            let output = try model.prediction(from: input)
            
            // 提取 embedding 向量
            return extractEmbedding(from: output)
            
        } catch {
            Logger.error("Local embedding inference failed: \(error)")
            return await fallbackToRemoteEmbedding(text)
        }
    }
    
    private func tokenize(_ text: String) -> [String] {
        // 简化分词（生产环境应使用 NaturalLanguage framework）
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }
    
    private func prepareInput(_ tokens: [String]) -> MLFeatureProvider {
        // TODO: 实现 token IDs 转换
        fatalError("Not implemented")
    }
    
    private func extractEmbedding(from output: MLFeatureProvider) -> [Float] {
        // TODO: 从模型输出中提取 embedding
        fatalError("Not implemented")
    }
    
    private func fallbackToRemoteEmbedding(_ text: String) async -> [Float] {
        // 调用远程 API
        []
    }
}
```

---

## 四、UI 交互设计

### 4.1 轻量徽章动画

```swift
@MainActor
class InstantFeedbackViewModel: ObservableObject {
    @Published var activeBadges: [BadgePresentation] = []
    
    func showBadge(for match: PhraseMatch) {
        let badge = BadgePresentation(
            id: UUID(),
            phraseBlockID: match.phraseBlockID,
            englishPhrase: match.phraseBlock.englishPhrase,
            confidence: match.confidence
        )
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            activeBadges.append(badge)
        }
        
        // 3 秒后自动消失
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation {
                activeBadges.removeAll { $0.id == badge.id }
            }
        }
    }
}

struct BadgePresentation: Identifiable {
    let id: UUID
    let phraseBlockID: UUID
    let englishPhrase: String
    let confidence: Double
}
```

```swift
struct InstantFeedbackBadgeView: View {
    let badge: BadgePresentation
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .imageScale(.medium)
            
            Text(badge.englishPhrase)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            Text("\(Int(badge.confidence * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.green.opacity(0.1))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                )
        )
        .transition(.scale.combined(with: .opacity))
    }
}
```

### 4.2 集成到对话视图

```swift
struct PracticeRoomView: View {
    @StateObject var viewModel: PracticeRoomViewModel
    @StateObject var feedbackViewModel: InstantFeedbackViewModel
    
    var body: some View {
        ZStack {
            // 对话主界面
            DialogueInterfaceView(viewModel: viewModel)
            
            // 即时反馈徽章（浮层）
            VStack {
                Spacer()
                
                ForEach(feedbackViewModel.activeBadges) { badge in
                    InstantFeedbackBadgeView(badge: badge)
                        .padding(.horizontal)
                }
                
                Spacer()
                    .frame(height: 100)  // 底部留白
            }
        }
    }
}
```

---

## 五、误命中防御机制

### 5.1 多层防御策略

**第一层：置信度阈值保守化**

```swift
// 阈值设置
private let confidenceThreshold: Double = 0.85  // 高于常规的 0.7-0.8

// 动态调整（基于误命中率监控）
actor ThresholdOptimizer {
    private var falsePositiveRate: Double = 0.0
    private let targetFalsePositiveRate: Double = 0.05  // 目标 < 5%
    
    func adjustThreshold() -> Double {
        if falsePositiveRate > targetFalsePositiveRate {
            // 误命中率过高，提高阈值
            return min(0.90, confidenceThreshold + 0.01)
        } else if falsePositiveRate < targetFalsePositiveRate * 0.5 {
            // 误命中率很低，可以适度降低阈值（提高召回率）
            return max(0.80, confidenceThreshold - 0.01)
        }
        return confidenceThreshold
    }
}
```

**第二层：语义等价二次验证**

```swift
// 不仅仅看相似度，还要判断语义是否等价
guard match.semanticEquivalence else {
    Logger.debug("Match filtered: high similarity but not semantically equivalent")
    continue
}
```

**第三层：上下文一致性检查**

```swift
actor ContextConsistencyChecker {
    func checkConsistency(
        userText: String,
        phraseBlock: PhraseBlock,
        dialogueContext: [Turn]
    ) -> Bool {
        // 检查用户使用的话术块是否符合当前对话上下文
        
        // 示例：如果话术块是关于"描述bug"的，但当前对话在讨论"设计方案"，
        // 则可能是误命中
        
        let recentTopics = extractTopics(from: dialogueContext)
        let phraseBlockTopics = phraseBlock.sceneTags
        
        let overlap = Set(recentTopics).intersection(Set(phraseBlockTopics))
        return !overlap.isEmpty
    }
    
    private func extractTopics(from turns: [Turn]) -> [String] {
        // 简化实现：提取最近几轮的关键词
        let recentTurns = turns.suffix(5)
        return recentTurns.flatMap { turn in
            // TODO: 实际应使用 NLP 提取主题
            turn.transcript.components(separatedBy: .whitespaces)
        }
    }
}
```

**第四层：用户申诉机制**

```swift
struct FeedbackAppeal: Codable {
    let matchID: UUID
    let userText: String
    let phraseBlockID: UUID
    let reason: String
    let timestamp: Date
}

actor AppealTracker {
    private var appeals: [FeedbackAppeal] = []
    
    func recordAppeal(_ appeal: FeedbackAppeal) async {
        appeals.append(appeal)
        
        // 上报到后端，用于模型优化
        await reportToBackend(appeal)
        
        // 本地立即生效：将该话术块标记为"需人工审核"
        await markForReview(appeal.phraseBlockID)
    }
    
    private func reportToBackend(_ appeal: FeedbackAppeal) async {
        // TODO: 上报到数据收集服务
    }
    
    private func markForReview(_ phraseBlockID: UUID) async {
        // TODO: 更新本地数据库
    }
}
```

### 5.2 误命中率监控

```swift
actor FalsePositiveMonitor {
    private var totalMatches: Int = 0
    private var reportedFalsePositives: Int = 0
    
    func recordMatch() {
        totalMatches += 1
    }
    
    func recordFalsePositive() {
        reportedFalsePositives += 1
    }
    
    func getFalsePositiveRate() -> Double {
        guard totalMatches > 0 else { return 0.0 }
        return Double(reportedFalsePositives) / Double(totalMatches)
    }
    
    func shouldTriggerAlert() -> Bool {
        let rate = getFalsePositiveRate()
        return totalMatches >= 100 && rate > 0.05  // 超过 5% 触发告警
    }
}
```

---

## 六、性能优化

### 6.1 批量匹配

```swift
// 后端 API 设计：支持批量匹配
struct BatchMatchRequest: Codable {
    let userText: String
    let phraseBlocks: [PhraseBlockSummary]  // 只传必要字段，减少数据量
}

struct PhraseBlockSummary: Codable {
    let id: UUID
    let englishPhrase: String
    let embedding: [Float]?  // 预计算的 embedding（可选）
}

// 单次 API 调用匹配所有话术块
let matches = try await apiService.batchMatch(
    userText: userText,
    phraseBlocks: activePhraseBlocks.map { $0.summary }
)
```

### 6.2 Embedding 缓存

```swift
actor EmbeddingCache {
    private var cache: [String: [Float]] = [:]
    private let maxCacheSize = 1000
    
    func getEmbedding(for text: String) async -> [Float]? {
        cache[text]
    }
    
    func setEmbedding(_ embedding: [Float], for text: String) {
        if cache.count >= maxCacheSize {
            // 简单 LRU：删除最早的
            if let firstKey = cache.keys.first {
                cache.removeValue(forKey: firstKey)
            }
        }
        cache[text] = embedding
    }
}

// 预计算话术块的 embedding
actor PhraseBlockPreprocessor {
    private let embeddingService: EmbeddingService
    private let cache: EmbeddingCache
    
    func preprocessPhraseBlocks(_ phraseBlocks: [PhraseBlock]) async {
        for phraseBlock in phraseBlocks {
            let embedding = await embeddingService.getEmbedding(phraseBlock.englishPhrase)
            await cache.setEmbedding(embedding, for: phraseBlock.englishPhrase)
        }
    }
}
```

### 6.3 并发控制

```swift
actor ConcurrencyLimiter {
    private var activeTaskCount = 0
    private let maxConcurrentTasks: Int
    
    init(maxConcurrentTasks: Int) {
        self.maxConcurrentTasks = maxConcurrentTasks
    }
    
    func acquire() async {
        while activeTaskCount >= maxConcurrentTasks {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        activeTaskCount += 1
    }
    
    func release() {
        activeTaskCount = max(0, activeTaskCount - 1)
    }
}

// 使用示例
let limiter = ConcurrencyLimiter(maxConcurrentTasks: 10)

for phraseBlock in activePhraseBlocks {
    Task {
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        
        await checkMatch(userText: userText, phraseBlock: phraseBlock)
    }
}
```

---

## 七、降级策略

### 7.1 降级触发条件

```swift
actor DegradationManager {
    private var recentLatencies: [TimeInterval] = []
    private var recentErrors: Int = 0
    private var isDegraded = false
    
    func checkShouldDegrade() -> Bool {
        // 条件 1：延迟持续超标
        let avgLatency = recentLatencies.reduce(0, +) / Double(recentLatencies.count)
        let latencyExceeded = avgLatency > 0.5
        
        // 条件 2：错误率过高
        let errorRate = Double(recentErrors) / Double(recentLatencies.count)
        let errorExceeded = errorRate > 0.2
        
        return latencyExceeded || errorExceeded
    }
    
    func enableDegradedMode() {
        isDegraded = true
        Logger.warning("Instant feedback degraded mode enabled")
    }
    
    func disableDegradedMode() {
        isDegraded = false
        Logger.info("Instant feedback degraded mode disabled")
    }
}
```

### 7.2 降级方案

**方案 1：关闭即时反馈**
- 检测完全关闭
- 用户不会看到徽章
- 实战使用次数仍然记录（通过回顾页事后分析）

**方案 2：降低检测频率**
- 从每句话检测改为每 N 句检测一次
- 或只检测较长的话轮（≥ 10 个词）

**方案 3：本地模糊匹配**
- 使用本地字符串匹配作为兜底
- 精度降低但保证基本可用

```swift
actor FallbackMatcher {
    func fuzzyMatch(userText: String, phraseBlocks: [PhraseBlock]) -> [PhraseMatch] {
        var matches: [PhraseMatch] = []
        
        for phraseBlock in phraseBlocks {
            let similarity = levenshteinSimilarity(
                userText.lowercased(),
                phraseBlock.englishPhrase.lowercased()
            )
            
            if similarity > 0.8 {  // 更高阈值，因为是模糊匹配
                matches.append(PhraseMatch(
                    phraseBlockID: phraseBlock.id,
                    phraseBlock: phraseBlock,
                    userText: userText,
                    confidence: similarity,
                    semanticEquivalence: false  // 模糊匹配不保证语义等价
                ))
            }
        }
        
        return matches
    }
    
    private func levenshteinSimilarity(_ str1: String, _ str2: String) -> Double {
        let distance = levenshteinDistance(str1, str2)
        let maxLength = max(str1.count, str2.count)
        return 1.0 - (Double(distance) / Double(maxLength))
    }
    
    private func levenshteinDistance(_ str1: String, _ str2: String) -> Int {
        let m = str1.count
        let n = str2.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        
        let str1Array = Array(str1)
        let str2Array = Array(str2)
        
        for i in 1...m {
            for j in 1...n {
                if str1Array[i - 1] == str2Array[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = min(
                        dp[i - 1][j] + 1,
                        dp[i][j - 1] + 1,
                        dp[i - 1][j - 1] + 1
                    )
                }
            }
        }
        
        return dp[m][n]
    }
}
```

---

## 八、测试策略

### 8.1 单元测试

```swift
@Test
func testConfidenceThresholdFiltering() async {
    let detector = InstantFeedbackDetector(/* ... */)
    
    let lowConfidenceMatch = PhraseMatch(
        phraseBlockID: UUID(),
        phraseBlock: testPhraseBlock,
        userText: "I think it's important",
        confidence: 0.75,  // 低于阈值 0.85
        semanticEquivalence: true
    )
    
    let validated = await detector.validateMatches([lowConfidenceMatch], userText: "...")
    
    #expect(validated.isEmpty, "Low confidence match should be filtered")
}

@Test
func testSemanticEquivalence() async {
    let matcher = HybridSemanticMatcher(/* ... */)
    
    // 语义相同
    let equivalent1 = await matcher.isSemanticEquivalent(
        "It's crucial to test this feature",
        "Testing this feature is critical"
    )
    #expect(equivalent1)
    
    // 语义不同
    let equivalent2 = await matcher.isSemanticEquivalent(
        "I like this design",
        "I disagree with this approach"
    )
    #expect(!equivalent2)
}
```

### 8.2 集成测试

```swift
@Test
func testEndToEndFeedbackFlow() async throws {
    let service = PracticeRoomService(/* ... */)
    
    // 启动会话
    try await service.startSession(/* ... */)
    
    // 模拟用户说出练习过的话术块
    let userUtterance = Utterance(
        id: UUID(),
        speaker: .user,
        transcript: "I think the main risk here is data consistency",
        timestamp: Date()
    )
    
    // 等待即时反馈事件
    var receivedFeedback = false
    for await event in await service.events {
        if case .phraseMatched = event {
            receivedFeedback = true
            break
        }
    }
    
    #expect(receivedFeedback, "Should receive instant feedback for matched phrase")
}
```

### 8.3 性能测试

```swift
@Test
func testDetectionLatency() async throws {
    let detector = InstantFeedbackDetector(/* ... */)
    
    let phraseBlocks = generateTestPhraseBlocks(count: 50)
    await detector.startMonitoring(sessionID: UUID(), phraseBlocks: phraseBlocks)
    
    let startTime = Date()
    let matches = await detector.detectMatches(userText: "I think this approach is critical")
    let latency = Date().timeIntervalSince(startTime)
    
    #expect(latency <= 0.5, "Detection latency \(latency)s exceeds 500ms target")
}
```

### 8.4 误命中率测试

```swift
@Test
func testFalsePositiveRate() async throws {
    let detector = InstantFeedbackDetector(/* ... */)
    
    // 准备测试数据：话术块 + 人工标注的正负样本
    let phraseBlocks = loadTestPhraseBlocks()
    let testCases = loadAnnotatedTestCases()  // 包含正样本和负样本
    
    await detector.startMonitoring(sessionID: UUID(), phraseBlocks: phraseBlocks)
    
    var falsePositives = 0
    var truePositives = 0
    var falseNegatives = 0
    
    for testCase in testCases {
        let matches = await detector.detectMatches(userText: testCase.userText)
        
        if testCase.shouldMatch {
            if matches?.contains(where: { $0.phraseBlockID == testCase.expectedPhraseBlockID }) == true {
                truePositives += 1
            } else {
                falseNegatives += 1
            }
        } else {
            if matches != nil && !matches!.isEmpty {
                falsePositives += 1
            }
        }
    }
    
    let falsePositiveRate = Double(falsePositives) / Double(testCases.count)
    let recall = Double(truePositives) / Double(truePositives + falseNegatives)
    
    #expect(falsePositiveRate < 0.05, "False positive rate \(falsePositiveRate) exceeds 5%")
    #expect(recall > 0.7, "Recall \(recall) too low")
}
```

---

## 九、监控与告警

### 9.1 关键指标

```swift
struct InstantFeedbackMetrics: Codable {
    let sessionID: String
    let detectionLatency: TimeInterval
    let matchCount: Int
    let falsePositiveCount: Int
    let totalPhraseBlocks: Int
    let apiCallSuccess: Bool
    let timestamp: Date
}

actor MetricsCollector {
    private var metrics: [InstantFeedbackMetrics] = []
    
    func recordMetrics(_ metrics: InstantFeedbackMetrics) async {
        self.metrics.append(metrics)
        
        // 实时告警
        if metrics.detectionLatency > 0.5 {
            await triggerAlert(.latencyExceeded(metrics.detectionLatency))
        }
        
        if !metrics.apiCallSuccess {
            await triggerAlert(.apiCallFailed)
        }
        
        // 定期上报
        if self.metrics.count >= 100 {
            await reportToBackend(self.metrics)
            self.metrics.removeAll()
        }
    }
    
    private func triggerAlert(_ alert: Alert) async {
        // TODO: 上报到监控系统
    }
    
    private func reportToBackend(_ metrics: [InstantFeedbackMetrics]) async {
        // TODO: 批量上报到后端
    }
}

enum Alert {
    case latencyExceeded(TimeInterval)
    case apiCallFailed
    case falsePositiveRateHigh(Double)
}
```

### 9.2 仪表盘指标

- **检测延迟**: P50/P90/P99
- **API 成功率**: 成功次数 / 总次数
- **匹配率**: 有匹配的话轮 / 总话轮
- **误命中率**: 用户申诉次数 / 总匹配次数
- **降级触发次数**: 降级模式启用次数

---

## 十、下一步

本文档完成了即时反馈系统的设计。后续文档将深入其他核心系统：

- [05_stall_rescue_mechanism.md](05_stall_rescue_mechanism.md): 卡壳救援机制
- [06_material_driven_engine.md](06_material_driven_engine.md): 素材驱动引擎
- [07_phrase_block_system.md](07_phrase_block_system.md): 话术块系统

---

**最后更新**: 2026-09-21  
**下一文档**: [05_stall_rescue_mechanism.md](05_stall_rescue_mechanism.md)
