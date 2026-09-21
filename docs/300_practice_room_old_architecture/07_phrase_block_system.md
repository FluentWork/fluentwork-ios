# 话术块系统设计

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 7  
**状态**: 设计阶段

---

## 一、设计目标

话术块是 FluentWork 的核心数据单元，记录用户练习过的英文表达。本文档设计其完整生命周期管理。

**核心功能**:
- 话术块状态管理（新建 → 训练 → 熟练 → 炼化）
- 实战使用次数追踪
- 调度准备（为即时反馈提供活跃话术块）
- 持久化存储（SwiftData）

---

## 二、数据模型

### 2.1 PhraseBlock Schema

```swift
import SwiftData

@Model
final class PhraseBlock {
    @Attribute(.unique) var id: UUID
    var userID: String
    
    // 内容
    var englishPhrase: String
    var chineseTranslation: String?
    var pronunciation: String?  // IPA 或音标
    
    // 元数据
    var sceneTags: [String]  // ["daily_standup", "design_review"]
    var difficultyLevel: Int  // 1-5
    
    // 状态
    var status: PhraseBlockStatus
    var practiceCount: Int
    var realWorldUsageCount: Int  // 实战使用次数
    
    // 来源
    var source: PhraseBlockSource
    var sourceSessionID: String?
    var distilledFromTurnID: UUID?
    
    // 时间戳
    var createdAt: Date
    var lastPracticedAt: Date?
    var lastUsedAt: Date?  // 最后一次实战使用
    var archivedAt: Date?
    
    init(
        id: UUID = UUID(),
        userID: String,
        englishPhrase: String,
        chineseTranslation: String? = nil,
        sceneTags: [String] = [],
        difficultyLevel: Int = 3,
        source: PhraseBlockSource
    ) {
        self.id = id
        self.userID = userID
        self.englishPhrase = englishPhrase
        self.chineseTranslation = chineseTranslation
        self.sceneTags = sceneTags
        self.difficultyLevel = difficultyLevel
        self.status = .new
        self.practiceCount = 0
        self.realWorldUsageCount = 0
        self.source = source
        self.createdAt = Date()
    }
}

enum PhraseBlockStatus: String, Codable {
    case new          // 新建，未练习
    case training     // 训练中
    case mastered     // 已熟练
    case distilled    // 已炼化（从回顾中提炼）
    case archived     // 已归档
}

enum PhraseBlockSource: String, Codable {
    case userCreated      // 用户手动创建
    case distilled        // 从会话炼化
    case imported         // 导入
    case suggested        // 系统推荐
}
```

### 2.2 状态转换

```
┌─────────┐
│   new   │ (新建)
└────┬────┘
     │ practice()
     ▼
┌─────────┐
│training │ (训练中)
└────┬────┘
     │ practiceCount >= 5
     ▼
┌─────────┐
│mastered │ (已熟练)
└────┬────┘
     │ realWorldUsageCount >= 3
     ▼
┌──────────┐
│distilled │ (已炼化)
└────┬─────┘
     │ archive()
     ▼
┌─────────┐
│archived │ (已归档)
└─────────┘
```

---

## 三、核心服务

### 3.1 PhraseBlockManager

```swift
actor PhraseBlockManager {
    private let persistence: PersistenceService
    
    // MARK: - Query
    
    func getActivePhraseBlocks(userID: String) async -> [PhraseBlock] {
        await persistence.fetchPhraseBlocks(
            userID: userID,
            statuses: [.new, .training, .mastered]
        )
    }
    
    func getPhraseBlock(id: UUID) async -> PhraseBlock? {
        await persistence.fetchPhraseBlock(id: id)
    }
    
    func searchPhraseBlocks(
        userID: String,
        query: String,
        tags: [String]? = nil
    ) async -> [PhraseBlock] {
        await persistence.searchPhraseBlocks(
            userID: userID,
            query: query,
            tags: tags
        )
    }
    
    // MARK: - Create
    
    func createPhraseBlock(
        userID: String,
        englishPhrase: String,
        chineseTranslation: String?,
        sceneTags: [String],
        source: PhraseBlockSource
    ) async throws -> PhraseBlock {
        let phraseBlock = PhraseBlock(
            userID: userID,
            englishPhrase: englishPhrase,
            chineseTranslation: chineseTranslation,
            sceneTags: sceneTags,
            source: source
        )
        
        try await persistence.save(phraseBlock)
        return phraseBlock
    }
    
    // MARK: - Update
    
    func recordPractice(phraseBlockID: UUID) async throws {
        guard let phraseBlock = await getPhraseBlock(id: phraseBlockID) else {
            throw PhraseBlockError.notFound
        }
        
        phraseBlock.practiceCount += 1
        phraseBlock.lastPracticedAt = Date()
        
        // 状态转换
        if phraseBlock.status == .new && phraseBlock.practiceCount >= 1 {
            phraseBlock.status = .training
        } else if phraseBlock.status == .training && phraseBlock.practiceCount >= 5 {
            phraseBlock.status = .mastered
        }
        
        try await persistence.save(phraseBlock)
    }
    
    func recordRealWorldUsage(phraseBlockID: UUID, sessionID: String) async {
        guard let phraseBlock = await getPhraseBlock(id: phraseBlockID) else {
            return
        }
        
        phraseBlock.realWorldUsageCount += 1
        phraseBlock.lastUsedAt = Date()
        
        // 状态转换：实战使用达标后自动炼化
        if phraseBlock.status == .mastered && phraseBlock.realWorldUsageCount >= 3 {
            phraseBlock.status = .distilled
        }
        
        try? await persistence.save(phraseBlock)
    }
    
    func updateStatus(phraseBlockID: UUID, newStatus: PhraseBlockStatus) async throws {
        guard let phraseBlock = await getPhraseBlock(id: phraseBlockID) else {
            throw PhraseBlockError.notFound
        }
        
        phraseBlock.status = newStatus
        
        if newStatus == .archived {
            phraseBlock.archivedAt = Date()
        }
        
        try await persistence.save(phraseBlock)
    }
    
    // MARK: - Delete
    
    func deletePhraseBlock(id: UUID) async throws {
        try await persistence.deletePhraseBlock(id: id)
    }
    
    // MARK: - Batch Operations
    
    func batchUpdateStatus(
        phraseBlockIDs: [UUID],
        newStatus: PhraseBlockStatus
    ) async throws {
        for id in phraseBlockIDs {
            try await updateStatus(phraseBlockID: id, newStatus: newStatus)
        }
    }
}

enum PhraseBlockError: Error {
    case notFound
    case invalidStatus
    case persistenceFailed
}
```

### 3.2 调度策略

```swift
actor PhraseBlockScheduler {
    private let manager: PhraseBlockManager
    
    func getScheduledPhraseBlocks(
        userID: String,
        sessionType: SessionType
    ) async -> [PhraseBlock] {
        let allActive = await manager.getActivePhraseBlocks(userID: userID)
        
        // 调度优先级：
        // 1. 最近练习过的（最近 7 天）
        // 2. 匹配会话场景标签的
        // 3. 训练中状态的优先于新建的
        
        let scheduled = allActive
            .filter { shouldSchedule($0, for: sessionType) }
            .sorted { lhs, rhs in
                priority(of: lhs) > priority(of: rhs)
            }
            .prefix(20)  // 限制数量，避免检测过载
        
        return Array(scheduled)
    }
    
    private func shouldSchedule(
        _ phraseBlock: PhraseBlock,
        for sessionType: SessionType
    ) -> Bool {
        // 只调度活跃状态的
        guard [.new, .training, .mastered].contains(phraseBlock.status) else {
            return false
        }
        
        // 最近 7 天练习过的优先
        if let lastPracticed = phraseBlock.lastPracticedAt {
            let daysSincePractice = Date().timeIntervalSince(lastPracticed) / 86400
            if daysSincePractice > 7 {
                return false
            }
        }
        
        return true
    }
    
    private func priority(of phraseBlock: PhraseBlock) -> Int {
        var score = 0
        
        // 状态权重
        switch phraseBlock.status {
        case .training:
            score += 30
        case .mastered:
            score += 20
        case .new:
            score += 10
        default:
            break
        }
        
        // 最近练习权重
        if let lastPracticed = phraseBlock.lastPracticedAt {
            let daysSince = Date().timeIntervalSince(lastPracticed) / 86400
            score += max(0, Int(10 - daysSince))  // 越近越高
        }
        
        // 练习次数权重
        score += min(phraseBlock.practiceCount, 10)
        
        return score
    }
}
```

---

## 四、持久化实现

### 4.1 SwiftData Container

```swift
actor PersistenceService {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    
    init() {
        let schema = Schema([
            PhraseBlock.self,
            PracticeSession.self,
            Review.self
        ])
        
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        
        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            modelContext = ModelContext(modelContainer)
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }
    
    // MARK: - Fetch
    
    func fetchPhraseBlocks(
        userID: String,
        statuses: [PhraseBlockStatus]
    ) async -> [PhraseBlock] {
        let predicate = #Predicate<PhraseBlock> { phraseBlock in
            phraseBlock.userID == userID &&
            statuses.contains(phraseBlock.status)
        }
        
        let descriptor = FetchDescriptor<PhraseBlock>(predicate: predicate)
        
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            Logger.error("Fetch failed: \(error)")
            return []
        }
    }
    
    func fetchPhraseBlock(id: UUID) async -> PhraseBlock? {
        let predicate = #Predicate<PhraseBlock> { $0.id == id }
        let descriptor = FetchDescriptor<PhraseBlock>(predicate: predicate)
        
        return try? modelContext.fetch(descriptor).first
    }
    
    func searchPhraseBlocks(
        userID: String,
        query: String,
        tags: [String]?
    ) async -> [PhraseBlock] {
        let predicate = #Predicate<PhraseBlock> { phraseBlock in
            phraseBlock.userID == userID &&
            (phraseBlock.englishPhrase.localizedStandardContains(query) ||
             (phraseBlock.chineseTranslation?.localizedStandardContains(query) ?? false))
        }
        
        let descriptor = FetchDescriptor<PhraseBlock>(predicate: predicate)
        
        do {
            var results = try modelContext.fetch(descriptor)
            
            // 标签过滤
            if let tags = tags, !tags.isEmpty {
                results = results.filter { phraseBlock in
                    !Set(phraseBlock.sceneTags).isDisjoint(with: Set(tags))
                }
            }
            
            return results
        } catch {
            Logger.error("Search failed: \(error)")
            return []
        }
    }
    
    // MARK: - Save
    
    func save(_ phraseBlock: PhraseBlock) async throws {
        modelContext.insert(phraseBlock)
        try modelContext.save()
    }
    
    // MARK: - Delete
    
    func deletePhraseBlock(id: UUID) async throws {
        guard let phraseBlock = await fetchPhraseBlock(id: id) else {
            throw PhraseBlockError.notFound
        }
        
        modelContext.delete(phraseBlock)
        try modelContext.save()
    }
}
```

---

## 五、测试策略

```swift
@Test
func testPhraseBlockLifecycle() async throws {
    let manager = PhraseBlockManager(/* ... */)
    
    // 1. 创建
    let phraseBlock = try await manager.createPhraseBlock(
        userID: "test-user",
        englishPhrase: "I think the main risk here is data consistency",
        chineseTranslation: "我认为主要风险是数据一致性",
        sceneTags: ["design_review"],
        source: .userCreated
    )
    
    #expect(phraseBlock.status == .new)
    #expect(phraseBlock.practiceCount == 0)
    
    // 2. 练习 1 次 → training
    try await manager.recordPractice(phraseBlockID: phraseBlock.id)
    let after1 = await manager.getPhraseBlock(id: phraseBlock.id)
    #expect(after1?.status == .training)
    
    // 3. 练习 5 次 → mastered
    for _ in 0..<4 {
        try await manager.recordPractice(phraseBlockID: phraseBlock.id)
    }
    let after5 = await manager.getPhraseBlock(id: phraseBlock.id)
    #expect(after5?.status == .mastered)
    
    // 4. 实战使用 3 次 → distilled
    for _ in 0..<3 {
        await manager.recordRealWorldUsage(
            phraseBlockID: phraseBlock.id,
            sessionID: UUID().uuidString
        )
    }
    let afterUsage = await manager.getPhraseBlock(id: phraseBlock.id)
    #expect(afterUsage?.status == .distilled)
}
```

---

**最后更新**: 2026-09-21  
**下一文档**: [08_state_management.md](08_state_management.md)
