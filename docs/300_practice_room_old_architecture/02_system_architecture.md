# 系统架构设计

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 2  
**状态**: 设计阶段

---

## 一、架构总览

### 1.1 分层架构

Practice Room 采用清晰的分层架构，基于已有的 TTS WebSocket 基础设施构建业务逻辑。

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation Layer                        │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────┐ │
│  │ PracticeRoomView│  │ ReviewView       │  │ BadgeView  │ │
│  │ (SwiftUI)       │  │ (SwiftUI)        │  │ (SwiftUI)  │ │
│  └────────┬────────┘  └────────┬─────────┘  └──────┬─────┘ │
│           │                    │                    │        │
│  ┌────────▼────────────────────▼────────────────────▼─────┐ │
│  │           PracticeRoomViewModel                         │ │
│  │           (@MainActor, ObservableObject)                │ │
│  └────────────────────────────┬────────────────────────────┘ │
└───────────────────────────────┼──────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────┐
│                      Domain Layer                             │
│  ┌──────────────────────────────────────────────────────────┐│
│  │         PracticeRoomService (Actor)                      ││
│  │   ┌──────────────┐  ┌─────────────┐  ┌───────────────┐ ││
│  │   │ SessionMgr   │  │ DialogueCtrl│  │ FeedbackCtrl  │ ││
│  │   └──────────────┘  └─────────────┘  └───────────────┘ ││
│  └──────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐│
│  │         Specialized Services (Actors)                    ││
│  │   ┌───────────────┐  ┌──────────────┐  ┌─────────────┐ ││
│  │   │MaterialProc   │  │InstantFeedback│ │StallRescue  │ ││
│  │   └───────────────┘  └──────────────┘  └─────────────┘ ││
│  │   ┌───────────────┐  ┌──────────────┐                  ││
│  │   │ReviewEngine   │  │PhraseBlockMgr│                  ││
│  │   └───────────────┘  └──────────────┘                  ││
│  └──────────────────────────────────────────────────────────┘│
└───────────────────────────────┬──────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────┐
│                  Infrastructure Layer                         │
│  ┌──────────────────────────────────────────────────────────┐│
│  │         VoiceSessionService (Actor)                      ││
│  │   (复用自 TTS WebSocket Architecture)                    ││
│  └──────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌───────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │WebSocketTrans │  │AudioEngine   │  │PersistenceLayer  │  │
│  │(Actor)        │  │(Actor)       │  │(Actor)           │  │
│  └───────────────┘  └──────────────┘  └──────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

### 1.2 核心模块职责

| 模块 | 职责 | Actor | 关键指标 |
|------|------|-------|----------|
| **PracticeRoomService** | 会话编排、状态管理、事件协调 | Actor | 编排延迟 < 50ms |
| **MaterialProcessor** | 素材提炼、场景生成、Prompt 构建 | Actor | 提炼耗时 ≤ 5s |
| **DialogueController** | 对话流控制、轮次管理、转录聚合 | Actor | 首响 P90 ≤ 1.5s |
| **InstantFeedbackDetector** | 话术块命中检测、实时反馈触发 | Actor | 检测延迟 ≤ 500ms |
| **StallRescueManager** | 卡壳检测、梯子生成、救援协调 | Actor | 触发延迟 ≤ 3s |
| **ReviewEngine** | 评价生成、双栏对照、话术块炼化 | Actor | 生成耗时 ≤ 15s |
| **PhraseBlockManager** | 话术块存储、状态管理、调度准备 | Actor | CRUD 延迟 < 100ms |
| **VoiceSessionService** | WebSocket 管理、音频流、协议处理 | Actor | 复用已有架构 |

### 1.3 关键设计决策

**决策 1: Actor 模型用于并发安全**
- **理由**: Swift Concurrency 提供编译时并发安全保证，避免数据竞争
- **影响**: 所有核心服务必须使用 `actor` 关键字，通过消息传递通信
- **权衡**: Actor 调用需要 `await`，增加少量延迟（< 1ms）

**决策 2: 事件驱动架构**
- **理由**: 实时检测、卡壳救援等需要并行处理，不能阻塞主对话流
- **影响**: 使用 `AsyncStream` 传递事件，ViewModel 订阅事件流
- **权衡**: 调试难度增加，需要完善的日志和监控

**决策 3: 复用 TTS WebSocket 基础设施**
- **理由**: 避免重复造轮子，已验证的并发安全模式
- **影响**: Practice Room 作为业务层，依赖 VoiceSessionService
- **权衡**: 受限于现有 WebSocket 协议，扩展性需要协调后端

**决策 4: 本地优先的状态管理**
- **理由**: 减少网络依赖，提升响应速度，支持离线场景
- **影响**: 使用 SwiftData 本地持久化，后台同步到服务器
- **权衡**: 需要处理同步冲突，增加数据一致性复杂度

---

## 二、核心模块设计

### 2.1 PracticeRoomService - 总协调者

**职责**: 会话生命周期管理、模块协调、事件分发

```swift
actor PracticeRoomService {
    // MARK: - Dependencies
    
    private let voiceService: VoiceSessionService
    private let materialProcessor: MaterialProcessor
    private let dialogueController: DialogueController
    private let feedbackDetector: InstantFeedbackDetector
    private let stallRescueManager: StallRescueManager
    private let reviewEngine: ReviewEngine
    private let phraseBlockManager: PhraseBlockManager
    
    // MARK: - State
    
    private var currentSession: PracticeSession?
    private var sessionState: SessionState = .idle
    
    // MARK: - Event Stream
    
    private let eventContinuation: AsyncStream<PracticeRoomEvent>.Continuation
    let events: AsyncStream<PracticeRoomEvent>
    
    // MARK: - Initialization
    
    init(dependencies: Dependencies) {
        self.voiceService = dependencies.voiceService
        self.materialProcessor = dependencies.materialProcessor
        self.dialogueController = dependencies.dialogueController
        self.feedbackDetector = dependencies.feedbackDetector
        self.stallRescueManager = dependencies.stallRescueManager
        self.reviewEngine = dependencies.reviewEngine
        self.phraseBlockManager = dependencies.phraseBlockManager
        
        (events, eventContinuation) = AsyncStream.makeStream()
    }
    
    // MARK: - Session Lifecycle
    
    func startSession(
        material: Material?,
        sceneType: ScenarioType,
        sessionType: SessionType,
        userID: String
    ) async throws -> UUID {
        guard sessionState == .idle else {
            throw PracticeRoomError.sessionAlreadyActive
        }
        
        sessionState = .preparing
        eventContinuation.yield(.sessionPreparing)
        
        // 1. 处理素材（如果提供）
        let processedMaterial: ProcessedMaterial?
        if let material = material {
            processedMaterial = try await materialProcessor.processMaterial(material)
        } else {
            processedMaterial = nil
        }
        
        // 2. 创建会话
        let sessionID = UUID()
        let session = PracticeSession(
            id: sessionID,
            userID: userID,
            materialID: material?.id,
            scenarioType: sceneType,
            sessionType: sessionType,
            processedMaterial: processedMaterial,
            startTime: Date()
        )
        currentSession = session
        
        // 3. 获取用户话术块（用于即时反馈）
        let userPhraseBlocks = await phraseBlockManager.getActivePhraseBlocks(userID: userID)
        
        // 4. 启动 Voice Session
        let voiceConfig = buildVoiceSessionConfig(
            sessionID: sessionID,
            processedMaterial: processedMaterial,
            sceneType: sceneType
        )
        try await voiceService.startSession(config: voiceConfig)
        
        // 5. 启动辅助服务
        await feedbackDetector.startMonitoring(
            sessionID: sessionID,
            phraseBlocks: userPhraseBlocks
        )
        
        if let processedMaterial = processedMaterial {
            await stallRescueManager.startMonitoring(
                sessionID: sessionID,
                dialogueContext: buildDialogueContext(processedMaterial)
            )
        }
        
        // 6. 订阅事件
        Task {
            await subscribeToVoiceEvents()
        }
        
        sessionState = .active
        eventContinuation.yield(.sessionStarted(sessionID))
        
        return sessionID
    }
    
    func endSession() async throws -> PracticeSession {
        guard let session = currentSession, sessionState == .active else {
            throw PracticeRoomError.noActiveSession
        }
        
        sessionState = .ending
        eventContinuation.yield(.sessionEnding)
        
        // 1. 停止辅助服务
        await feedbackDetector.stopMonitoring()
        await stallRescueManager.stopMonitoring()
        
        // 2. 结束 Voice Session
        try await voiceService.endSession()
        
        // 3. 获取完整转录
        let turns = await dialogueController.getAllTurns()
        
        // 4. 更新会话记录
        var completedSession = session
        completedSession.endTime = Date()
        completedSession.turns = turns
        completedSession.status = .completed
        
        // 5. 触发异步评价生成与话术块炼化
        Task {
            await generateReviewAndDistill(for: completedSession)
        }
        
        // 6. 清理状态
        sessionState = .idle
        currentSession = nil
        eventContinuation.yield(.sessionEnded(session.id))
        
        return completedSession
    }
    
    func pauseSession() async throws {
        guard sessionState == .active else {
            throw PracticeRoomError.invalidStateTransition
        }
        
        sessionState = .paused
        await voiceService.pause()
        eventContinuation.yield(.sessionPaused)
    }
    
    func resumeSession() async throws {
        guard sessionState == .paused else {
            throw PracticeRoomError.invalidStateTransition
        }
        
        sessionState = .active
        await voiceService.resume()
        eventContinuation.yield(.sessionResumed)
    }
    
    func abandonSession() async {
        guard let session = currentSession else { return }
        
        // 停止所有服务
        await feedbackDetector.stopMonitoring()
        await stallRescueManager.stopMonitoring()
        try? await voiceService.endSession()
        
        // 标记为放弃
        var abandonedSession = session
        abandonedSession.status = .abandoned
        abandonedSession.endTime = Date()
        
        sessionState = .idle
        currentSession = nil
        eventContinuation.yield(.sessionAbandoned(session.id))
    }
    
    // MARK: - Event Handling
    
    private func subscribeToVoiceEvents() async {
        for await event in voiceService.events {
            await handleVoiceEvent(event)
        }
    }
    
    private func handleVoiceEvent(_ event: VoiceSessionEvent) async {
        switch event {
        case .userUtteranceCompleted(let utterance):
            await handleUserUtterance(utterance)
            
        case .aiUtteranceCompleted(let utterance):
            await handleAIUtterance(utterance)
            
        case .aiAudioStarted:
            eventContinuation.yield(.aiSpeaking)
            
        case .transcriptUpdate(let text):
            eventContinuation.yield(.transcriptUpdate(text))
            
        case .error(let error):
            eventContinuation.yield(.error(.voiceSessionFailed(error)))
        }
    }
    
    private func handleUserUtterance(_ utterance: Utterance) async {
        guard let session = currentSession else { return }
        
        // 1. 记录话轮
        await dialogueController.addTurn(utterance)
        
        // 2. 触发即时反馈检测（并行，不阻塞）
        Task {
            await checkInstantFeedback(utterance)
        }
        
        // 3. 通知卡壳救援系统（用户说话了，重置计时器）
        await stallRescueManager.onUserSpeaking()
        
        eventContinuation.yield(.userSpoke(utterance))
    }
    
    private func handleAIUtterance(_ utterance: Utterance) async {
        // 1. 记录话轮
        await dialogueController.addTurn(utterance)
        
        // 2. 通知卡壳救援系统（AI 说话了，开始监控用户沉默）
        await stallRescueManager.onAISpeaking()
        
        eventContinuation.yield(.aiSpoke(utterance))
    }
    
    private func checkInstantFeedback(_ utterance: Utterance) async {
        guard let matches = await feedbackDetector.detectMatches(
            userText: utterance.transcript
        ) else { return }
        
        for match in matches {
            // 记录命中（实战使用次数 +1）
            await phraseBlockManager.recordRealWorldUsage(
                phraseBlockID: match.phraseBlockID,
                sessionID: currentSession?.id.uuidString ?? ""
            )
            
            // 触发反馈
            eventContinuation.yield(.phraseMatched(match))
            
            // 通知 AI（在下一轮自然确认）
            await voiceService.injectContext(
                "User just used a practiced phrase: '\(match.phraseBlock.englishPhrase)'"
            )
        }
    }
    
    // MARK: - Review & Distillation
    
    private func generateReviewAndDistill(for session: PracticeSession) async {
        do {
            // 并行生成评价和炼化话术块
            async let review = reviewEngine.generateReview(
                sessionID: session.id,
                turns: session.turns,
                material: session.processedMaterial
            )
            
            async let phraseBlocks = reviewEngine.distillPhraseBlocks(
                sessionID: session.id,
                turns: session.turns
            )
            
            let (generatedReview, distilledPhraseBlocks) = try await (review, phraseBlocks)
            
            eventContinuation.yield(.reviewGenerated(generatedReview))
            eventContinuation.yield(.phraseBlocksDistilled(distilledPhraseBlocks))
            
        } catch {
            eventContinuation.yield(.error(.reviewGenerationFailed(error)))
        }
    }
    
    // MARK: - Helpers
    
    private func buildVoiceSessionConfig(
        sessionID: UUID,
        processedMaterial: ProcessedMaterial?,
        sceneType: ScenarioType
    ) -> VoiceSessionConfig {
        let systemPrompt: String
        if let material = processedMaterial {
            systemPrompt = material.aiRolePrompt
        } else {
            systemPrompt = buildPresetScenarioPrompt(sceneType)
        }
        
        return VoiceSessionConfig(
            sessionID: sessionID.uuidString,
            systemPrompt: systemPrompt,
            enableInstantFeedback: true,
            enableStallRescue: true
        )
    }
    
    private func buildPresetScenarioPrompt(_ sceneType: ScenarioType) -> String {
        switch sceneType {
        case .dailyStandup:
            return """
            You are a tech lead in a Daily Standup meeting.
            
            Ask the user about:
            1. What they did yesterday
            2. What they're working on today
            3. Any blockers they're facing
            
            Keep questions natural and conversational. Listen actively and ask follow-up questions.
            """
            
        case .designReview:
            return """
            You are a senior engineer in a Design Review meeting.
            
            Discuss with the user about their technical design, focusing on:
            1. Architecture decisions
            2. Trade-offs and alternatives
            3. Edge cases and error handling
            
            Challenge their assumptions respectfully and suggest improvements.
            """
            
        case .custom:
            return "You are a helpful colleague ready to discuss work topics."
            
        case .demo:
            return "You are conducting a demo session. Ask the user to present their work."
        }
    }
    
    private func buildDialogueContext(_ material: ProcessedMaterial) -> String {
        let topics = material.extractedTopics.joined(separator: ", ")
        let terms = material.keyTerms.joined(separator: ", ")
        return "Topics: \(topics). Key terms: \(terms)."
    }
}

// MARK: - Supporting Types

struct Dependencies {
    let voiceService: VoiceSessionService
    let materialProcessor: MaterialProcessor
    let dialogueController: DialogueController
    let feedbackDetector: InstantFeedbackDetector
    let stallRescueManager: StallRescueManager
    let reviewEngine: ReviewEngine
    let phraseBlockManager: PhraseBlockManager
}

enum SessionState {
    case idle
    case preparing
    case active
    case paused
    case ending
}

enum PracticeRoomEvent {
    case sessionPreparing
    case sessionStarted(UUID)
    case sessionPaused
    case sessionResumed
    case sessionEnding
    case sessionEnded(UUID)
    case sessionAbandoned(UUID)
    
    case userSpoke(Utterance)
    case aiSpeaking
    case aiSpoke(Utterance)
    case transcriptUpdate(String)
    
    case phraseMatched(PhraseMatch)
    case stallDetected(StallTrigger)
    case rescueProvided(RescueLevel, String)
    
    case reviewGenerated(Review)
    case phraseBlocksDistilled([PhraseBlock])
    
    case error(PracticeRoomError)
}

enum PracticeRoomError: Error {
    case sessionAlreadyActive
    case noActiveSession
    case invalidStateTransition
    case materialProcessingFailed(Error)
    case voiceSessionFailed(Error)
    case reviewGenerationFailed(Error)
}
```

### 2.2 MaterialProcessor - 素材处理引擎

**职责**: 素材提炼、场景生成、Prompt 构建

```swift
actor MaterialProcessor {
    private let apiService: PracticeRoomAPIService
    private let cache: MaterialCache
    
    func processMaterial(_ material: Material) async throws -> ProcessedMaterial {
        let startTime = Date()
        
        // 检查缓存
        if let cached = await cache.get(material) {
            return cached
        }
        
        // 提炼素材
        let extracted = try await apiService.extractMaterial(content: material.content)
        
        // 构建场景设定
        let sceneSetup = SceneSetup(
            scenario: extracted.suggestedScenario,
            userRole: "Software Engineer",
            aiRole: extracted.suggestedAIRole,
            objective: buildObjective(from: extracted)
        )
        
        // 生成 AI 角色 Prompt
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
            aiRolePrompt: aiRolePrompt
        )
        
        // 验证处理时间（目标 ≤ 5s）
        let duration = Date().timeIntervalSince(startTime)
        if duration > 5.0 {
            Logger.warning("Material processing took \(duration)s, exceeds 5s target")
        }
        
        // 缓存结果
        await cache.set(material, processed)
        
        return processed
    }
    
    private func buildObjective(from extracted: ExtractedMaterial) -> String {
        if extracted.discussionPoints.isEmpty {
            return "Discuss the provided material naturally"
        } else {
            return "Guide discussion through these points: \(extracted.discussionPoints.joined(separator: "; "))"
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
        - Key terms: \(extracted.keyTerms.joined(separator: ", "))
        
        Your objectives:
        1. Ask questions related to these discussion points:
           \(extracted.discussionPoints.enumerated().map { "   \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        
        2. **At least 60% of your questions must reference the provided context**
        
        3. Use natural, conversational English suitable for workplace tech discussions
        
        4. Keep questions focused and avoid going off-topic
        
        5. If the user uses a practiced phrase (you'll be notified), acknowledge it naturally
        
        6. If the user gets stuck, the system will provide a ladder - DO NOT repeat your question
        
        Important behavioral rules:
        - NEVER repeat your previous question if the user is silent
        - DO NOT ask "Can you elaborate?" or similar generic follow-ups when user is stuck
        - Listen actively and build on what the user says
        - Maintain a supportive, collaborative tone
        """
    }
}

// MARK: - Cache

actor MaterialCache {
    private var storage: [UUID: ProcessedMaterial] = [:]
    private let maxEntries = 50
    
    func get(_ material: Material) -> ProcessedMaterial? {
        storage[material.id]
    }
    
    func set(_ material: Material, _ processed: ProcessedMaterial) {
        // 简单 LRU：超过上限删除最早的
        if storage.count >= maxEntries {
            if let oldestKey = storage.keys.min(by: { _, _ in true }) {
                storage.removeValue(forKey: oldestKey)
            }
        }
        storage[material.id] = processed
    }
}
```

### 2.3 InstantFeedbackDetector - 即时反馈系统

**职责**: 实时检测话术块命中、触发反馈事件

```swift
actor InstantFeedbackDetector {
    private let apiService: PracticeRoomAPIService
    private let confidenceThreshold: Double = 0.85  // 保守阈值
    
    private var sessionID: UUID?
    private var activePhraseBlocks: [PhraseBlock] = []
    private var isMonitoring = false
    
    func startMonitoring(sessionID: UUID, phraseBlocks: [PhraseBlock]) {
        self.sessionID = sessionID
        self.activePhraseBlocks = phraseBlocks
        self.isMonitoring = true
    }
    
    func stopMonitoring() {
        isMonitoring = false
        sessionID = nil
        activePhraseBlocks = []
    }
    
    func detectMatches(userText: String) async -> [PhraseMatch]? {
        guard isMonitoring, !activePhraseBlocks.isEmpty else {
            return nil
        }
        
        let startTime = Date()
        
        // 调用后端匹配服务
        do {
            let matches = try await apiService.matchPhraseBlocks(
                userText: userText,
                phraseBlocks: activePhraseBlocks
            )
            
            // 过滤低置信度匹配
            let filteredMatches = matches.filter {
                $0.confidence >= confidenceThreshold && $0.semanticEquivalence
            }
            
            // 验证延迟（目标 ≤ 500ms）
            let duration = Date().timeIntervalSince(startTime)
            if duration > 0.5 {
                Logger.warning("Match detection took \(duration * 1000)ms, exceeds 500ms target")
            }
            
            return filteredMatches.isEmpty ? nil : filteredMatches
            
        } catch {
            Logger.error("Match detection failed: \(error)")
            return nil
        }
    }
}
```

### 2.4 StallRescueManager - 卡壳救援机制

**职责**: 卡壳检测、梯子生成、救援协调

```swift
actor StallRescueManager {
    private let apiService: PracticeRoomAPIService
    private let silenceThreshold: TimeInterval = 3.0
    
    private var sessionID: UUID?
    private var dialogueContext: String?
    private var isMonitoring = false
    
    private var silenceTimer: Task<Void, Never>?
    private var currentLevel: RescueLevel = .skeleton
    private var lastRescueTime: Date?
    
    func startMonitoring(sessionID: UUID, dialogueContext: String) {
        self.sessionID = sessionID
        self.dialogueContext = dialogueContext
        self.isMonitoring = true
        self.currentLevel = .skeleton
    }
    
    func stopMonitoring() {
        isMonitoring = false
        silenceTimer?.cancel()
        sessionID = nil
        dialogueContext = nil
        lastRescueTime = nil
    }
    
    func onUserSpeaking() {
        // 用户开始说话，取消沉默计时器，重置救援层级
        silenceTimer?.cancel()
        silenceTimer = nil
        currentLevel = .skeleton
    }
    
    func onAISpeaking() {
        // AI 说完话，开始监控用户沉默
        guard isMonitoring else { return }
        
        silenceTimer?.cancel()
        silenceTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(silenceThreshold * 1_000_000_000))
            
            // 沉默超时，触发救援
            if !Task.isCancelled {
                await triggerRescue()
            }
        }
    }
    
    private func triggerRescue() async {
        guard let sessionID = sessionID,
              let dialogueContext = dialogueContext else {
            return
        }
        
        do {
            let rescueContext = RescueContext(
                sessionID: sessionID.uuidString,
                recentTurns: [],  // TODO: 从 DialogueController 获取
                currentSilenceDuration: silenceThreshold,
                dialogueContext: dialogueContext
            )
            
            // 生成对应层级的梯子
            let ladder = try await apiService.generateRescueLadder(
                context: rescueContext,
                level: currentLevel
            )
            
            lastRescueTime = Date()
            
            // TODO: 通过 TTS 播放梯子
            // await voiceService.playRescueLadder(ladder)
            
            // 升级到下一层级（如果用户还是不说话）
            if currentLevel.rawValue < 3 {
                currentLevel = RescueLevel(rawValue: currentLevel.rawValue + 1) ?? .fullExpression
            }
            
        } catch {
            Logger.error("Rescue generation failed: \(error)")
        }
    }
}
```

### 2.5 ReviewEngine - 评价与炼化引擎

**职责**: 评价生成、双栏对照、话术块炼化

```swift
actor ReviewEngine {
    private let apiService: PracticeRoomAPIService
    
    func generateReview(
        sessionID: UUID,
        turns: [Turn],
        material: ProcessedMaterial?
    ) async throws -> Review {
        let startTime = Date()
        
        let review = try await apiService.generateReview(
            sessionID: sessionID.uuidString,
            transcript: turns,
            material: material?.materialID
        )
        
        // 验证生成时间（目标 ≤ 15s）
        let duration = Date().timeIntervalSince(startTime)
        if duration > 15.0 {
            Logger.warning("Review generation took \(duration)s, exceeds 15s target")
        }
        
        return review
    }
    
    func distillPhraseBlocks(
        sessionID: UUID,
        turns: [Turn]
    ) async throws -> [PhraseBlock] {
        try await apiService.distillPhraseBlocks(
            sessionID: sessionID.uuidString,
            transcript: turns
        )
    }
}
```

### 2.6 PhraseBlockManager - 话术块管理

**职责**: 话术块存储、状态管理、调度准备

```swift
actor PhraseBlockManager {
    private let persistence: PersistenceService
    
    func getActivePhraseBlocks(userID: String) async -> [PhraseBlock] {
        await persistence.fetchPhraseBlocks(
            userID: userID,
            statuses: [.new, .training]
        )
    }
    
    func recordRealWorldUsage(phraseBlockID: UUID, sessionID: String) async {
        await persistence.incrementRealWorldUsageCount(phraseBlockID: phraseBlockID)
    }
    
    func savePhraseBlock(_ phraseBlock: PhraseBlock) async throws {
        try await persistence.save(phraseBlock)
    }
    
    func updateStatus(phraseBlockID: UUID, newStatus: PhraseBlockStatus) async throws {
        try await persistence.updatePhraseBlockStatus(
            id: phraseBlockID,
            status: newStatus
        )
    }
}
```

---

## 三、模块交互设计

### 3.1 会话启动序列

```
User                     ViewModel                PracticeRoomService       VoiceSessionService
 │                          │                           │                          │
 │─── tapStart ──────────>  │                           │                          │
 │                          │─── startSession ───────>  │                          │
 │                          │                           │─── processMaterial ────> MaterialProcessor
 │                          │                           │<────── processed ────────│
 │                          │                           │                          │
 │                          │                           │─── startSession ───────> │
 │                          │                           │                          │─── WebSocket.connect
 │                          │                           │                          │<─── connected
 │                          │                           │<───── started ───────────│
 │                          │                           │                          │
 │                          │                           │─── startMonitoring ────> FeedbackDetector
 │                          │                           │─── startMonitoring ────> StallRescueManager
 │                          │                           │                          │
 │                          │<──── sessionStarted ──────│                          │
 │<─── showRecording ───────│                           │                          │
 │                          │                          │                          │
```

### 3.2 用户话轮处理流程

```
User speaks              VoiceSession         PracticeRoomService      FeedbackDetector     StallRescueManager
    │                        │                        │                      │                      │
    │─── audio ────────────> │                        │                      │                      │
    │                        │─── ASR ────────>       │                      │                      │
    │                        │<─── transcript ─────   │                      │                      │
    │                        │                        │                      │                      │
    │                        │─── utteranceCompleted ─>                      │                      │
    │                        │                        │─── detectMatches ──> │                      │
    │                        │                        │                      │─── API call          │
    │                        │                        │                      │<─── matches          │
    │                        │                        │<─── phraseMatched ───│                      │
    │                        │                        │                      │                      │
    │                        │                        │─── onUserSpeaking ────────────────────────> │
    │                        │                        │                      │                   (cancel timer)
    │                        │                        │                      │                      │
```

### 3.3 卡壳救援流程

```
User silent              StallRescueManager     APIService           VoiceSession         User
    │                          │                      │                    │                │
    │                          │─── startTimer (3s)   │                    │                │
    │                          │                      │                    │                │
    │ (silence 3s)             │                      │                    │                │
    │                          │─── generateLadder ─> │                    │                │
    │                          │    (Level 1)         │                    │                │
    │                          │<─── ladder ──────────│                    │                │
    │                          │                      │                    │                │
    │                          │─── playRescueLadder ─────────────────────> │                │
    │                          │                      │                    │─── TTS audio ─>│
    │                          │                      │                    │                │
    │                          │─── startTimer (5s)   │                    │                │
    │                          │    (for Level 2)     │                    │                │
```

---

## 四、数据流设计

### 4.1 状态管理

```swift
@MainActor
class PracticeRoomViewModel: ObservableObject {
    @Published var sessionState: SessionState = .idle
    @Published var currentTranscript: [Turn] = []
    @Published var matchedPhraseBlocks: [PhraseMatch] = []
    @Published var isAISpeaking = false
    @Published var liveTranscriptText = ""
    
    private let practiceRoomService: PracticeRoomService
    private var eventSubscription: Task<Void, Never>?
    
    init(practiceRoomService: PracticeRoomService) {
        self.practiceRoomService = practiceRoomService
        subscribeToEvents()
    }
    
    func startSession(material: Material?, sceneType: ScenarioType) async {
        do {
            let sessionID = try await practiceRoomService.startSession(
                material: material,
                sceneType: sceneType,
                sessionType: .standard,
                userID: getCurrentUserID()
            )
            sessionState = .active
        } catch {
            // Handle error
        }
    }
    
    private func subscribeToEvents() {
        eventSubscription = Task {
            for await event in await practiceRoomService.events {
                await handleEvent(event)
            }
        }
    }
    
    private func handleEvent(_ event: PracticeRoomEvent) async {
        switch event {
        case .sessionStarted:
            sessionState = .active
            
        case .userSpoke(let utterance):
            currentTranscript.append(utterance)
            
        case .aiSpoke(let utterance):
            currentTranscript.append(utterance)
            isAISpeaking = false
            
        case .aiSpeaking:
            isAISpeaking = true
            
        case .phraseMatched(let match):
            matchedPhraseBlocks.append(match)
            showBadge(for: match)
            
        case .transcriptUpdate(let text):
            liveTranscriptText = text
            
        case .sessionEnded:
            sessionState = .completed
            
        default:
            break
        }
    }
    
    private func showBadge(for match: PhraseMatch) {
        // 展示轻量徽章动画
    }
    
    private func getCurrentUserID() -> String {
        // 从用户管理服务获取
        "user-123"
    }
}
```

### 4.2 错误处理策略

**分层错误处理**:

```swift
// 领域错误
enum PracticeRoomError: Error {
    case sessionAlreadyActive
    case noActiveSession
    case invalidStateTransition
    case materialProcessingFailed(Error)
    case voiceSessionFailed(Error)
    case reviewGenerationFailed(Error)
}

// 网络错误
enum NetworkError: Error {
    case connectionFailed
    case timeout
    case serverError(Int)
    case decodingFailed
}

// 音频错误
enum AudioError: Error {
    case sessionInterrupted
    case permissionDenied
    case deviceUnavailable
}

// 错误处理器
actor ErrorHandler {
    func handle(_ error: Error, context: String) async -> RecoveryAction {
        switch error {
        case let networkError as NetworkError:
            return handleNetworkError(networkError, context: context)
            
        case let audioError as AudioError:
            return handleAudioError(audioError, context: context)
            
        case let practiceRoomError as PracticeRoomError:
            return handlePracticeRoomError(practiceRoomError, context: context)
            
        default:
            return .showAlert("An unexpected error occurred")
        }
    }
    
    private func handleNetworkError(_ error: NetworkError, context: String) -> RecoveryAction {
        switch error {
        case .connectionFailed:
            return .retry(maxAttempts: 3, backoff: .exponential)
            
        case .timeout:
            return .retry(maxAttempts: 2, backoff: .linear)
            
        case .serverError(let code) where code >= 500:
            return .retry(maxAttempts: 1, backoff: .exponential)
            
        default:
            return .showAlert("Network error: \(error)")
        }
    }
    
    private func handleAudioError(_ error: AudioError, context: String) -> RecoveryAction {
        switch error {
        case .sessionInterrupted:
            return .pauseAndNotify("Audio session interrupted. Tap to resume.")
            
        case .permissionDenied:
            return .requestPermission(.microphone)
            
        case .deviceUnavailable:
            return .showAlert("Microphone unavailable. Please check your device.")
        }
    }
    
    private func handlePracticeRoomError(_ error: PracticeRoomError, context: String) -> RecoveryAction {
        switch error {
        case .sessionAlreadyActive:
            return .showAlert("A session is already active")
            
        case .noActiveSession:
            return .navigateToHome
            
        case .voiceSessionFailed(let underlying):
            return .retry(maxAttempts: 1, backoff: .none)
            
        default:
            return .showAlert("\(error)")
        }
    }
}

enum RecoveryAction {
    case retry(maxAttempts: Int, backoff: BackoffStrategy)
    case showAlert(String)
    case pauseAndNotify(String)
    case requestPermission(PermissionType)
    case navigateToHome
}

enum BackoffStrategy {
    case none
    case linear
    case exponential
}
```

---

## 五、依赖注入设计

```swift
// 依赖容器
actor DependencyContainer {
    private let apiService: PracticeRoomAPIService
    private let persistenceService: PersistenceService
    private let voiceSessionService: VoiceSessionService
    
    init() {
        // 初始化基础设施
        self.apiService = DefaultPracticeRoomAPIService()
        self.persistenceService = SwiftDataPersistenceService()
        self.voiceSessionService = VoiceSessionService()
    }
    
    func makePracticeRoomService() async -> PracticeRoomService {
        let dependencies = PracticeRoomService.Dependencies(
            voiceService: voiceSessionService,
            materialProcessor: makeMaterialProcessor(),
            dialogueController: makeDialogueController(),
            feedbackDetector: makeInstantFeedbackDetector(),
            stallRescueManager: makeStallRescueManager(),
            reviewEngine: makeReviewEngine(),
            phraseBlockManager: makePhraseBlockManager()
        )
        
        return PracticeRoomService(dependencies: dependencies)
    }
    
    private func makeMaterialProcessor() -> MaterialProcessor {
        MaterialProcessor(
            apiService: apiService,
            cache: MaterialCache()
        )
    }
    
    private func makeDialogueController() -> DialogueController {
        DialogueController()
    }
    
    private func makeInstantFeedbackDetector() -> InstantFeedbackDetector {
        InstantFeedbackDetector(apiService: apiService)
    }
    
    private func makeStallRescueManager() -> StallRescueManager {
        StallRescueManager(apiService: apiService)
    }
    
    private func makeReviewEngine() -> ReviewEngine {
        ReviewEngine(apiService: apiService)
    }
    
    private func makePhraseBlockManager() -> PhraseBlockManager {
        PhraseBlockManager(persistence: persistenceService)
    }
}

// App 启动
@main
struct FluentWorkApp: App {
    let container = DependencyContainer()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    let practiceRoomService = await container.makePracticeRoomService()
                    // 注入到环境
                }
        }
    }
}
```

---

## 六、技术债务与后续优化

### 6.1 已知限制

1. **素材缓存简单**: 当前使用内存缓存，应迁移到持久化缓存
2. **救援层级固定**: 未根据用户水平动态调整
3. **命中检测单后端**: 应考虑本地 embedding 模型加速
4. **状态持久化缺失**: 异常退出后无法恢复会话

### 6.2 性能优化方向

1. **预连接**: 进入房间前预建 WebSocket 连接
2. **Prompt 预加载**: 常用场景 Prompt 缓存
3. **并行优化**: 评价生成与炼化并行
4. **本地 embedding**: 使用 Core ML 本地计算相似度

### 6.3 可扩展性预留

1. **多模型路由**: 接口支持切换不同 LLM 提供商
2. **发音评测接口**: 预留 Turn 中的 pronunciationScore 字段
3. **团队功能**: 数据模型支持 teamID、共享话术块
4. **场景库扩展**: ScenarioType 支持动态加载

---

## 七、下一步

本文档完成了系统架构设计，定义了核心模块及其职责。后续文档将深入每个模块的技术细节：

- [03_realtime_dialogue_design.md](03_realtime_dialogue_design.md): WebSocket 对话链路设计
- [04_instant_feedback_system.md](04_instant_feedback_system.md): 语义匹配与并行检测
- [05_stall_rescue_mechanism.md](05_stall_rescue_mechanism.md): 卡壳检测与三层梯子
- [06_material_driven_engine.md](06_material_driven_engine.md): 素材提炼与场景生成
- [07_phrase_block_system.md](07_phrase_block_system.md): 话术块管理与调度

---

**最后更新**: 2026-09-21  
**下一文档**: [03_realtime_dialogue_design.md](03_realtime_dialogue_design.md)
