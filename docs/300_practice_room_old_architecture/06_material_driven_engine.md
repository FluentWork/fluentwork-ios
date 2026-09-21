# 素材驱动引擎设计

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 6  
**状态**: 设计阶段

---

## 一、设计目标

素材驱动引擎负责将用户的真实工作素材（文本、描述）转化为可用于对话演练的结构化场景。

**PRD 核心原则**:
> 练习内容由用户真实工作素材生成，预置场景只做冷启动兜底。这是与通用口语产品的分水岭。

**技术指标**:
- 提炼耗时 ≤ 5s
- 素材引用率 ≥ 60%（AI 话轮中引用素材内容）
- 支持 ≤2000 字的文本输入
- 生成高质量的对话 Prompt

---

## 二、核心功能

### 2.1 素材提炼流程

```
用户输入素材
    ↓
文本预处理（清洗、分段）
    ↓
AI 提炼
    ├─ 主题识别
    ├─ 关键术语提取
    ├─ 讨论点生成
    └─ 场景建议
    ↓
场景设定构建
    ├─ 用户角色
    ├─ AI 角色
    ├─ 对话目标
    └─ 上下文
    ↓
生成 AI System Prompt
    ↓
缓存结果
```

### 2.2 素材类型

```swift
enum MaterialInput {
    case text(String)                    // 粘贴文本（≤2000字）
    case description(String)              // 一句话描述（≥10字）
    case preset(ScenarioType)            // 预置场景
    case demo                            // 演示素材
}

struct Material: Identifiable, Codable {
    let id: UUID
    let userID: String
    let content: String
    let sourceType: MaterialSourceType
    let createdAt: Date
}
```

---

## 三、实现设计

### 3.1 MaterialProcessor

```swift
actor MaterialProcessor {
    private let apiService: PracticeRoomAPIService
    private let cache: MaterialCache
    private let validator: MaterialValidator
    
    func processMaterial(_ material: Material) async throws -> ProcessedMaterial {
        let startTime = Date()
        
        // 1. 检查缓存
        if let cached = await cache.get(material) {
            Logger.info("Material cache hit: \(material.id)")
            return cached
        }
        
        // 2. 验证输入
        try validator.validate(material)
        
        // 3. 提炼素材
        let extracted = try await apiService.extractMaterial(content: material.content)
        
        // 4. 构建场景设定
        let sceneSetup = buildSceneSetup(from: extracted)
        
        // 5. 生成 AI Prompt
        let aiRolePrompt = buildAIRolePrompt(
            setup: sceneSetup,
            extracted: extracted
        )
        
        let processed = ProcessedMaterial(
            materialID: material.id,
            extractedTopics: extracted.topics,
            keyTerms: extracted.keyTerms,
            discussionPoints: extracted.discussionPoints,
            sceneSetup: sceneSetup,
            aiRolePrompt: aiRolePrompt,
            processedAt: Date()
        )
        
        // 6. 验证处理时间
        let duration = Date().timeIntervalSince(startTime)
        if duration > 5.0 {
            Logger.warning("Material processing took \(duration)s, exceeds 5s target")
        }
        
        // 7. 缓存结果
        await cache.set(material, processed)
        
        return processed
    }
    
    private func buildSceneSetup(from extracted: ExtractedMaterial) -> SceneSetup {
        SceneSetup(
            scenario: extracted.suggestedScenario.rawValue,
            userRole: "Software Engineer",
            aiRole: extracted.suggestedAIRole,
            objective: buildObjective(from: extracted)
        )
    }
    
    private func buildObjective(from extracted: ExtractedMaterial) -> String {
        if extracted.discussionPoints.isEmpty {
            return "Discuss the provided material naturally"
        } else {
            let points = extracted.discussionPoints.prefix(3).joined(separator: "; ")
            return "Guide discussion through: \(points)"
        }
    }
    
    private func buildAIRolePrompt(
        setup: SceneSetup,
        extracted: ExtractedMaterial
    ) -> String {
        """
        You are \(setup.aiRole) in a \(setup.scenario).
        
        Context:
        - User's role: \(setup.userRole)
        - Discussion topics: \(extracted.topics.joined(separator: ", "))
        - Key technical terms: \(extracted.keyTerms.joined(separator: ", "))
        
        Your objectives:
        \(extracted.discussionPoints.enumerated().map { "   \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        
        Critical requirements:
        1. **At least 60% of your questions MUST reference the provided context**
           - Mention specific topics or terms from the context
           - Build on the discussion points provided
           - Do NOT ask generic questions unrelated to the material
        
        2. Use natural, conversational English suitable for workplace tech discussions
        
        3. Ask focused questions - avoid going off-topic
        
        4. If the user uses a practiced phrase (you'll be notified), acknowledge naturally
        
        5. If user gets stuck, system will provide rescue ladder - DO NOT repeat questions
        
        6. Listen actively and build on what the user says
        
        7. Keep a supportive, collaborative tone
        """
    }
}
```

### 3.2 素材验证

```swift
actor MaterialValidator {
    func validate(_ material: Material) throws {
        // 长度检查
        guard material.content.count >= 10 else {
            throw ValidationError.tooShort
        }
        
        guard material.content.count <= 2000 else {
            throw ValidationError.tooLong
        }
        
        // 语言检查（支持中英文混合）
        guard containsValidContent(material.content) else {
            throw ValidationError.invalidContent
        }
    }
    
    private func containsValidContent(_ text: String) -> Bool {
        // 至少包含一些字母或中文字符
        let hasLetters = text.rangeOfCharacter(from: .letters) != nil
        let hasChinese = text.range(of: "[\\u4e00-\\u9fa5]", options: .regularExpression) != nil
        return hasLetters || hasChinese
    }
}

enum ValidationError: Error {
    case tooShort
    case tooLong
    case invalidContent
}
```

### 3.3 素材提炼 API

```swift
// POST /api/materials/extract
struct ExtractMaterialRequest: Codable {
    let content: String
    let language: String  // "zh", "en", "mixed"
}

struct ExtractedMaterial: Codable {
    let topics: [String]              // 3-5 个主题
    let keyTerms: [String]            // 5-10 个关键技术术语
    let discussionPoints: [String]    // 3-5 个讨论点
    let suggestedScenario: ScenarioType
    let suggestedAIRole: String
    let complexity: ComplexityLevel
}

enum ComplexityLevel: String, Codable {
    case beginner
    case intermediate
    case advanced
}
```

---

## 四、素材引用率保障

### 4.1 Prompt 强制注入

```swift
private func buildAIRolePrompt(/* ... */) -> String {
    """
    Critical requirements:
    1. **At least 60% of your questions MUST reference the provided context**
       - Mention specific topics: \(extracted.topics.joined(separator: ", "))
       - Use key terms: \(extracted.keyTerms.joined(separator: ", "))
    """
}
```

### 4.2 话轮引用检测

```swift
actor MaterialReferenceTracker {
    private var totalAITurns: Int = 0
    private var referencingTurns: Int = 0
    
    func trackTurn(aiResponse: String, material: ProcessedMaterial) {
        totalAITurns += 1
        
        if containsReference(aiResponse, material: material) {
            referencingTurns += 1
        }
    }
    
    func getReferenceRate() -> Double {
        guard totalAITurns > 0 else { return 0.0 }
        return Double(referencingTurns) / Double(totalAITurns)
    }
    
    private func containsReference(_ text: String, material: ProcessedMaterial) -> Bool {
        let keywords = material.extractedTopics + material.keyTerms
        let lowercasedText = text.lowercased()
        
        return keywords.contains { keyword in
            lowercasedText.contains(keyword.lowercased())
        }
    }
}
```

### 4.3 引用率告警

```swift
actor ReferenceRateMonitor {
    private let targetRate: Double = 0.6
    private let tracker: MaterialReferenceTracker
    
    func checkAndAlert(sessionID: UUID) async {
        let rate = await tracker.getReferenceRate()
        
        if rate < targetRate {
            Logger.warning("Material reference rate \(rate) below target \(targetRate)")
            await triggerAlert(sessionID: sessionID, rate: rate)
        }
    }
    
    private func triggerAlert(sessionID: UUID, rate: Double) async {
        // 上报到监控系统
    }
}
```

---

## 五、预置场景

### 5.1 Daily Standup

```swift
func buildDailyStandupScenario() -> ProcessedMaterial {
    ProcessedMaterial(
        materialID: UUID(),
        extractedTopics: ["yesterday's work", "today's plan", "blockers"],
        keyTerms: ["sprint", "task", "blocker", "progress"],
        discussionPoints: [
            "What did you work on yesterday?",
            "What are you working on today?",
            "Are there any blockers?"
        ],
        sceneSetup: SceneSetup(
            scenario: "Daily Standup Meeting",
            userRole: "Software Engineer",
            aiRole: "Tech Lead",
            objective: "Share progress and identify blockers"
        ),
        aiRolePrompt: """
        You are a Tech Lead in a Daily Standup meeting.
        
        Ask the user about:
        1. What they did yesterday
        2. What they're working on today
        3. Any blockers they're facing
        
        Keep it brief (standup should be quick), natural, and supportive.
        """,
        processedAt: Date()
    )
}
```

### 5.2 演示素材

```swift
func buildDemoMaterial() -> ProcessedMaterial {
    ProcessedMaterial(
        materialID: UUID(),
        extractedTopics: ["API design", "database migration", "performance"],
        keyTerms: ["REST API", "PostgreSQL", "indexing", "response time"],
        discussionPoints: [
            "Explain the API design decisions",
            "Discuss the database migration strategy",
            "How to optimize query performance"
        ],
        sceneSetup: SceneSetup(
            scenario: "Design Review",
            userRole: "Backend Engineer",
            aiRole: "Senior Engineer",
            objective: "Review technical design decisions"
        ),
        aiRolePrompt: """
        You are a Senior Engineer reviewing a backend design.
        
        The user will explain their API design and database migration approach.
        
        Ask about:
        - Why they chose REST over GraphQL
        - How they'll handle backward compatibility during migration
        - What indexing strategy they plan for performance
        
        Challenge assumptions respectfully and suggest alternatives.
        """,
        processedAt: Date()
    )
}
```

---

## 六、缓存策略

### 6.1 内存缓存

```swift
actor MaterialCache {
    private var storage: [UUID: CachedMaterial] = [:]
    private let maxEntries = 50
    private let expirationInterval: TimeInterval = 3600  // 1 hour
    
    func get(_ material: Material) -> ProcessedMaterial? {
        guard let cached = storage[material.id] else {
            return nil
        }
        
        // 检查是否过期
        if Date().timeIntervalSince(cached.timestamp) > expirationInterval {
            storage.removeValue(forKey: material.id)
            return nil
        }
        
        return cached.processed
    }
    
    func set(_ material: Material, _ processed: ProcessedMaterial) {
        // LRU eviction
        if storage.count >= maxEntries {
            evictOldest()
        }
        
        storage[material.id] = CachedMaterial(
            processed: processed,
            timestamp: Date()
        )
    }
    
    private func evictOldest() {
        guard let oldestKey = storage.min(by: { $0.value.timestamp < $1.value.timestamp })?.key else {
            return
        }
        storage.removeValue(forKey: oldestKey)
    }
}

struct CachedMaterial {
    let processed: ProcessedMaterial
    let timestamp: Date
}
```

---

## 七、测试策略

```swift
@Test
func testMaterialProcessing() async throws {
    let processor = MaterialProcessor(/* ... */)
    
    let material = Material(
        id: UUID(),
        userID: "test-user",
        content: """
        我们团队正在重构认证模块，需要从旧的 JWT 方案迁移到新的 OAuth2。
        主要挑战是如何在不影响现有用户的情况下完成迁移。
        """,
        sourceType: .text
    )
    
    let processed = try await processor.processMaterial(material)
    
    #expect(!processed.extractedTopics.isEmpty)
    #expect(processed.extractedTopics.contains(where: { $0.contains("认证") || $0.contains("迁移") }))
    #expect(!processed.keyTerms.isEmpty)
    #expect(!processed.discussionPoints.isEmpty)
}

@Test
func testReferenceRateTracking() async {
    let tracker = MaterialReferenceTracker()
    let material = buildTestMaterial()
    
    // AI 引用了素材
    await tracker.trackTurn(
        aiResponse: "Tell me more about your JWT to OAuth2 migration strategy",
        material: material
    )
    
    // AI 没引用素材
    await tracker.trackTurn(
        aiResponse: "How's the weather today?",
        material: material
    )
    
    let rate = await tracker.getReferenceRate()
    #expect(rate == 0.5)  // 1/2 = 50%
}
```

---

## 八、下一步

- [07_phrase_block_system.md](07_phrase_block_system.md): 话术块系统
- [08_state_management.md](08_state_management.md): 状态管理

---

**最后更新**: 2026-09-21  
**下一文档**: [07_phrase_block_system.md](07_phrase_block_system.md)
