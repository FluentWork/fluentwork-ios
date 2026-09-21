# 卡壳救援机制设计

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 5  
**状态**: 设计阶段

---

## 一、设计目标与背景

卡壳救援机制是 FluentWork 的核心护城河功能之一，也是设计原则 4"干预分层"在对话流内的**唯一实现**。

**PRD §5.4 核心观点**:
> 这是设计原则 4 在对话流内唯一的实现，也是这个品类的流失时刻。听说薄弱的程序员第一次卡壳 5 秒无人救援，就会认定"这个产品让我难堪"——而他要练的恰恰是最没把握的部分。

**三条硬约束**:
1. **不追问**: 卡壳时 AI 重复原问题是最糟的反应
2. **不离开语音流**: 骨架与提示走 TTS 说出来，不弹卡片
3. **不记入失败**: 被救援过的话术块照常进入炼化候选

**技术指标**:
- 触发延迟 ≤ 3s
- 三层梯子逐层升级，不跳层
- 救援有效率 ≥ 70%（用户继续说话）
- 不依赖风险 < 30%（用户等梯子而不是先尝试）

---

## 二、系统架构

### 2.1 整体流程

```
AI 说完话
    ↓
开始监控用户沉默
    ↓
沉默 3 秒？
    ├─ NO → 用户开始说话，取消监控
    └─ YES → 触发 Layer 1 救援
              ↓
         生成句首骨架
              ↓
         TTS 播放梯子
              ↓
         等待 5 秒
              ↓
         用户还是沉默？
              ├─ NO → 用户说话了，救援成功
              └─ YES → 升级到 Layer 2
                        ↓
                   生成中文意图提示
                        ↓
                   TTS 播放提示
                        ↓
                   等待 5 秒
                        ↓
                   用户还是沉默？
                        ├─ NO → 用户说话了，救援成功
                        └─ YES → 升级到 Layer 3
                                  ↓
                             给完整表达
                                  ↓
                             TTS 播放
                                  ↓
                             继续对话
```

### 2.2 状态机

```swift
enum RescueState {
    case monitoring           // 正常监控，等待用户说话
    case silenceDetected      // 检测到沉默
    case layer1Triggered      // Layer 1 已触发
    case layer1WaitingResponse // 等待 Layer 1 后的用户反应
    case layer2Triggered      // Layer 2 已触发
    case layer2WaitingResponse // 等待 Layer 2 后的用户反应
    case layer3Triggered      // Layer 3 已触发
    case resolved             // 救援成功，用户继续说话
    case idle                 // 未监控
}
```

---

## 三、核心实现

### 3.1 StallRescueManager

```swift
actor StallRescueManager {
    // MARK: - Dependencies
    
    private let apiService: PracticeRoomAPIService
    private let ttsService: TTSService
    
    // MARK: - Configuration
    
    private let silenceThreshold: TimeInterval = 3.0
    private let layerWaitTime: TimeInterval = 5.0
    
    // MARK: - State
    
    private var sessionID: UUID?
    private var dialogueContext: DialogueContext?
    private var isMonitoring = false
    
    private var state: RescueState = .idle
    private var silenceTimer: Task<Void, Never>?
    private var layerWaitTimer: Task<Void, Never>?
    private var currentLayer: RescueLevel = .skeleton
    private var lastRescueTime: Date?
    
    // MARK: - Metrics
    
    private var totalRescues: Int = 0
    private var successfulRescues: Int = 0
    private var layerDistribution: [RescueLevel: Int] = [:]
    
    // MARK: - Lifecycle
    
    func startMonitoring(sessionID: UUID, dialogueContext: DialogueContext) {
        self.sessionID = sessionID
        self.dialogueContext = dialogueContext
        self.isMonitoring = true
        self.state = .idle
        self.currentLayer = .skeleton
        
        Logger.info("Started stall rescue monitoring")
    }
    
    func stopMonitoring() {
        isMonitoring = false
        silenceTimer?.cancel()
        layerWaitTimer?.cancel()
        sessionID = nil
        dialogueContext = nil
        state = .idle
        
        Logger.info("Stopped stall rescue monitoring")
    }
    
    // MARK: - Event Handlers
    
    func onUserSpeaking() {
        // 用户开始说话
        silenceTimer?.cancel()
        layerWaitTimer?.cancel()
        
        // 如果之前触发了救援，记录为成功
        if state != .idle && state != .monitoring {
            successfulRescues += 1
            Logger.info("Rescue successful at \(currentLayer)")
        }
        
        // 重置状态
        state = .monitoring
        currentLayer = .skeleton
    }
    
    func onAISpeaking() {
        // AI 说完话，开始监控用户沉默
        guard isMonitoring else { return }
        
        state = .monitoring
        startSilenceTimer()
    }
    
    // MARK: - Silence Detection
    
    private func startSilenceTimer() {
        silenceTimer?.cancel()
        
        silenceTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(silenceThreshold * 1_000_000_000))
            
            if !Task.isCancelled && state == .monitoring {
                await triggerRescue(level: .skeleton)
            }
        }
    }
    
    // MARK: - Rescue Triggering
    
    private func triggerRescue(level: RescueLevel) async {
        guard let sessionID = sessionID,
              let dialogueContext = dialogueContext else {
            return
        }
        
        totalRescues += 1
        currentLayer = level
        layerDistribution[level, default: 0] += 1
        
        Logger.info("Triggering rescue at \(level)")
        
        do {
            // 1. 生成梯子
            let ladder = try await generateLadder(
                level: level,
                sessionID: sessionID,
                dialogueContext: dialogueContext
            )
            
            // 2. 更新状态
            switch level {
            case .skeleton:
                state = .layer1Triggered
            case .intentHint:
                state = .layer2Triggered
            case .fullExpression:
                state = .layer3Triggered
            }
            
            // 3. 通过 TTS 播放梯子
            await playLadderViaTTS(ladder)
            
            // 4. 等待用户反应
            if level != .fullExpression {
                await startLayerWaitTimer(currentLevel: level)
            } else {
                // Layer 3 是最后一层，不再等待
                state = .resolved
            }
            
        } catch {
            Logger.error("Rescue generation failed: \(error)")
            // 失败后降级：直接给 Layer 3
            if level != .fullExpression {
                await triggerRescue(level: .fullExpression)
            }
        }
    }
    
    private func generateLadder(
        level: RescueLevel,
        sessionID: UUID,
        dialogueContext: DialogueContext
    ) async throws -> RescueLadder {
        let context = RescueContext(
            sessionID: sessionID.uuidString,
            recentTurns: dialogueContext.recentTurns,
            currentSilenceDuration: silenceThreshold,
            dialogueContext: dialogueContext.summary
        )
        
        return try await apiService.generateRescueLadder(
            context: context,
            level: level
        )
    }
    
    private func playLadderViaTTS(_ ladder: RescueLadder) async {
        // 使用友好的语气播放梯子
        let ttsConfig = TTSConfig(
            text: ladder.text,
            voice: .helpful,  // 使用友好、支持性的语音
            speed: 0.9        // 稍慢一点，给用户思考时间
        )
        
        await ttsService.speak(config: ttsConfig)
    }
    
    // MARK: - Layer Wait Timer
    
    private func startLayerWaitTimer(currentLevel: RescueLevel) async {
        layerWaitTimer?.cancel()
        
        layerWaitTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(layerWaitTime * 1_000_000_000))
            
            if !Task.isCancelled {
                await checkAndEscalate(from: currentLevel)
            }
        }
    }
    
    private func checkAndEscalate(from level: RescueLevel) async {
        // 检查用户是否还在沉默
        let stillSilent = await isUserStillSilent()
        
        if stillSilent {
            // 升级到下一层
            let nextLevel = level.next()
            if let nextLevel = nextLevel {
                await triggerRescue(level: nextLevel)
            } else {
                // 已经是 Layer 3，没有下一层了
                state = .resolved
            }
        } else {
            // 用户说话了，救援成功
            state = .resolved
            successfulRescues += 1
        }
    }
    
    private func isUserStillSilent() async -> Bool {
        // 检查当前状态
        switch state {
        case .layer1WaitingResponse, .layer2WaitingResponse:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Metrics
    
    func getRescueMetrics() -> RescueMetrics {
        RescueMetrics(
            totalRescues: totalRescues,
            successfulRescues: successfulRescues,
            successRate: totalRescues > 0 ? Double(successfulRescues) / Double(totalRescues) : 0.0,
            layerDistribution: layerDistribution
        )
    }
}

// MARK: - Supporting Types

struct DialogueContext {
    let recentTurns: [Turn]
    let summary: String
    let materialTopics: [String]
}

struct RescueContext: Codable {
    let sessionID: String
    let recentTurns: [Turn]
    let currentSilenceDuration: TimeInterval
    let dialogueContext: String
}

enum RescueLevel: Int, Codable {
    case skeleton = 1       // 句首骨架
    case intentHint = 2     // 中文意图提示
    case fullExpression = 3 // 完整表达
    
    func next() -> RescueLevel? {
        RescueLevel(rawValue: self.rawValue + 1)
    }
}

struct RescueLadder: Codable {
    let level: RescueLevel
    let text: String
    let audioURL: URL?
}

struct RescueMetrics {
    let totalRescues: Int
    let successfulRescues: Int
    let successRate: Double
    let layerDistribution: [RescueLevel: Int]
}
```

### 3.2 梯子生成策略

**Layer 1: 句首骨架**

```
输入: 
- AI 最后的问题: "What did you work on yesterday?"
- 对话上下文: 讨论 Daily Standup

输出:
"I worked on..." 或
"Yesterday I..." 或
"The main thing I did was..."
```

**Layer 2: 中文意图提示**

```
输入: 同上

输出:
"可以先说你做了什么，再说遇到了什么问题" 或
"试着描述一下你完成的任务"
```

**Layer 3: 完整表达**

```
输入: 同上

输出:
"I worked on refactoring the authentication module. 
I completed the migration to the new API and fixed several edge cases."
```

### 3.3 后端 API 契约

```swift
// POST /api/rescue/generate-ladder
struct GenerateRescueLadderRequest: Codable {
    let sessionID: String
    let level: RescueLevel
    let aiLastQuestion: String
    let userRecentUtterances: [String]
    let dialogueContext: String
    let materialTopics: [String]
}

struct GenerateRescueLadderResponse: Codable {
    let ladder: RescueLadder
    let alternativeLadders: [String]?  // 备选梯子
    let generationTime: TimeInterval
}
```

---

## 四、关键约束的实现

### 4.1 约束 1: 不追问

**问题**: 用户卡在"What did you work on?"，AI 不能重复"So, what did you work on?"

**实现**:
- 后端生成梯子时，明确标记"不要重复原问题"
- 梯子的内容是"帮助用户回答"，而不是"重新问问题"

```swift
// Prompt 示例
let rescuePrompt = """
User is stuck on the question: "\(aiLastQuestion)"

Generate a helpful ladder to help them answer, NOT repeat the question.

Level 1: Provide sentence starters like "I worked on..." or "Yesterday I..."
Level 2: Provide intent hints in Chinese like "可以先说做了什么，再说遇到什么问题"
Level 3: Provide a complete example answer

DO NOT repeat or rephrase the original question.
"""
```

### 4.2 约束 2: 不离开语音流

**问题**: 梯子必须通过 TTS 语音播放，不能弹卡片或切换页面

**实现**:
- 所有梯子文本都通过 `TTSService` 播放
- UI 层不展示任何卡片或弹窗
- 可选：在实时转录浮层显示梯子文本（视觉辅助）

```swift
// 可选：在转录浮层显示梯子
@MainActor
func displayLadderInTranscript(_ ladder: RescueLadder) {
    transcriptViewModel.addSystemMessage(
        text: "💡 \(ladder.text)",
        style: .hint
    )
}
```

### 4.3 约束 3: 不记入失败

**问题**: 被救援过的话术块不能标记为"失败"，应该进入炼化候选

**实现**:
- 救援事件不影响话术块状态
- 回顾页炼化时，卡壳点作为"素材来源"（PRD: 卡壳点正是最该练的东西）

```swift
// 在 DialogueController 中记录救援事件
struct RescueEvent: Codable {
    let turnID: UUID
    let rescueLevel: RescueLevel
    let ladderText: String
    let timestamp: Date
    let userContinued: Bool
}

// 回顾页炼化时，优先提炼卡壳点
func prioritizeStallPoints(turns: [Turn], rescueEvents: [RescueEvent]) -> [Turn] {
    let stallTurnIDs = Set(rescueEvents.map(\.turnID))
    
    return turns.filter { turn in
        turn.speaker == .user && stallTurnIDs.contains(turn.id)
    }
}
```

---

## 五、依赖风险防御

### 5.1 问题定义

**风险**（PRD §十二）:
> 梯子给得太早，用户会等梯子而不是先尝试。

**目标**: 救援触发率 < 30%

### 5.2 防御策略

**策略 1: 3 秒阈值**
- 给用户足够思考时间
- 不能太快，否则用户会依赖

**策略 2: 逐层升级**
- Layer 1 只给轻量提示
- 不一次性给答案

**策略 3: 监控救援率**

```swift
actor RescueDependencyMonitor {
    private var totalTurns: Int = 0
    private var turnsWithRescue: Int = 0
    
    func recordTurn(hadRescue: Bool) {
        totalTurns += 1
        if hadRescue {
            turnsWithRescue += 1
        }
    }
    
    func getRescueTriggerRate() -> Double {
        guard totalTurns > 0 else { return 0.0 }
        return Double(turnsWithRescue) / Double(totalTurns)
    }
    
    func shouldAlert() -> Bool {
        totalTurns >= 50 && getRescueTriggerRate() > 0.3
    }
    
    func getRecommendation() -> String {
        let rate = getRescueTriggerRate()
        
        if rate > 0.4 {
            return "救援率过高(\(Int(rate * 100))%)，建议降低场景难度或增加沉默阈值"
        } else if rate < 0.1 {
            return "救援率很低(\(Int(rate * 100))%)，可以适度降低阈值提供更多帮助"
        } else {
            return "救援率正常(\(Int(rate * 100))%)"
        }
    }
}
```

**策略 4: A/B 测试不同阈值**

```swift
enum RescueConfig {
    case conservative  // 5 秒触发
    case standard      // 3 秒触发
    case aggressive    // 2 秒触发
    
    var silenceThreshold: TimeInterval {
        switch self {
        case .conservative: return 5.0
        case .standard: return 3.0
        case .aggressive: return 2.0
        }
    }
}

// 根据用户分组使用不同配置
let config: RescueConfig = userID.hashValue % 3 == 0 ? .conservative : .standard
```

---

## 六、测试策略

### 6.1 单元测试

```swift
@Test
func testSilenceDetection() async {
    let manager = StallRescueManager(/* ... */)
    
    await manager.startMonitoring(sessionID: UUID(), dialogueContext: testContext)
    await manager.onAISpeaking()
    
    // 等待 3 秒
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    
    // 应该触发 Layer 1
    let metrics = await manager.getRescueMetrics()
    #expect(metrics.totalRescues == 1)
    #expect(metrics.layerDistribution[.skeleton] == 1)
}

@Test
func testUserSpeakingCancelsRescue() async {
    let manager = StallRescueManager(/* ... */)
    
    await manager.startMonitoring(sessionID: UUID(), dialogueContext: testContext)
    await manager.onAISpeaking()
    
    // 2 秒后用户说话
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    await manager.onUserSpeaking()
    
    // 不应该触发救援
    let metrics = await manager.getRescueMetrics()
    #expect(metrics.totalRescues == 0)
}

@Test
func testLayerEscalation() async {
    let manager = StallRescueManager(/* ... */)
    
    await manager.startMonitoring(sessionID: UUID(), dialogueContext: testContext)
    await manager.onAISpeaking()
    
    // 等待 3s (Layer 1) + 5s (Layer 2) + 5s (Layer 3)
    try? await Task.sleep(nanoseconds: 13_000_000_000)
    
    let metrics = await manager.getRescueMetrics()
    #expect(metrics.totalRescues == 3)  // 应触发所有三层
    #expect(metrics.layerDistribution[.skeleton] == 1)
    #expect(metrics.layerDistribution[.intentHint] == 1)
    #expect(metrics.layerDistribution[.fullExpression] == 1)
}
```

### 6.2 集成测试

```swift
@Test
func testEndToEndRescueFlow() async throws {
    let service = PracticeRoomService(/* ... */)
    
    try await service.startSession(/* ... */)
    
    // 等待救援事件
    var receivedRescue = false
    for await event in await service.events {
        if case .rescueProvided = event {
            receivedRescue = true
            break
        }
    }
    
    #expect(receivedRescue)
}
```

---

## 七、监控与指标

### 7.1 关键指标

```swift
struct RescueAnalytics: Codable {
    let sessionID: String
    let totalTurns: Int
    let rescueTriggerCount: Int
    let rescueTriggerRate: Double
    
    let layer1Count: Int
    let layer2Count: Int
    let layer3Count: Int
    
    let successfulRescues: Int
    let successRate: Double
    
    let avgRescueLatency: TimeInterval
    let timestamp: Date
}
```

### 7.2 仪表盘

- **救援触发率**: 触发救援的话轮 / 总话轮（目标 < 30%）
- **救援有效率**: 用户继续说话 / 触发次数（目标 ≥ 70%）
- **层级分布**: Layer 1/2/3 的比例（期望大部分在 Layer 1）
- **触发延迟**: 沉默开始到梯子播放的时间（目标 ≤ 3s）

---

## 八、下一步

本文档完成了卡壳救援机制的设计。后续文档：

- [06_material_driven_engine.md](06_material_driven_engine.md): 素材驱动引擎
- [07_phrase_block_system.md](07_phrase_block_system.md): 话术块系统

---

**最后更新**: 2026-09-21  
**下一文档**: [06_material_driven_engine.md](06_material_driven_engine.md)
