# 测试策略

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 10  
**状态**: 设计阶段

---

## 一、测试金字塔

```
           ┌───────────┐
          ╱   E2E Tests  ╲     10%
         ╱      (UI)      ╲
        ┌─────────────────┐
       ╱ Integration Tests ╲   30%
      ╱    (API, Actors)    ╲
     ┌───────────────────────┐
    ╱   Unit Tests            ╲  60%
   ╱  (Pure Logic, Models)     ╲
  └───────────────────────────┘
```

**覆盖率目标**:
- 核心业务逻辑: ≥ 90%
- UI 层: ≥ 60%
- 整体项目: ≥ 80%

---

## 二、单元测试

### 2.1 测试框架

```swift
import Testing  // Swift Testing (iOS 17+)

@Suite("Phrase Block Manager Tests")
struct PhraseBlockManagerTests {
    var manager: PhraseBlockManager!
    var mockPersistence: MockPersistenceService!
    
    init() async throws {
        mockPersistence = MockPersistenceService()
        manager = PhraseBlockManager(persistence: mockPersistence)
    }
    
    @Test("Create phrase block")
    func testCreatePhraseBlock() async throws {
        let phraseBlock = try await manager.createPhraseBlock(
            userID: "test-user",
            englishPhrase: "Let's schedule a follow-up meeting",
            chineseTranslation: "我们安排一个后续会议",
            sceneTags: ["meeting"],
            source: .userCreated
        )
        
        #expect(phraseBlock.status == .new)
        #expect(phraseBlock.practiceCount == 0)
        #expect(phraseBlock.sceneTags.contains("meeting"))
    }
    
    @Test("Record practice transitions status")
    func testRecordPracticeStateTransition() async throws {
        // 创建话术块
        let phraseBlock = try await manager.createPhraseBlock(
            userID: "test-user",
            englishPhrase: "Test phrase",
            chineseTranslation: nil,
            sceneTags: [],
            source: .userCreated
        )
        
        #expect(phraseBlock.status == .new)
        
        // 练习 1 次 → training
        try await manager.recordPractice(phraseBlockID: phraseBlock.id)
        let afterFirst = await manager.getPhraseBlock(id: phraseBlock.id)
        #expect(afterFirst?.status == .training)
        #expect(afterFirst?.practiceCount == 1)
        
        // 练习到 5 次 → mastered
        for _ in 0..<4 {
            try await manager.recordPractice(phraseBlockID: phraseBlock.id)
        }
        let afterFive = await manager.getPhraseBlock(id: phraseBlock.id)
        #expect(afterFive?.status == .mastered)
        #expect(afterFive?.practiceCount == 5)
    }
    
    @Test("Real world usage triggers distilled state")
    func testRealWorldUsageTransition() async throws {
        let phraseBlock = try await manager.createPhraseBlock(
            userID: "test-user",
            englishPhrase: "Test phrase",
            chineseTranslation: nil,
            sceneTags: [],
            source: .userCreated
        )
        
        // 先到 mastered 状态
        for _ in 0..<5 {
            try await manager.recordPractice(phraseBlockID: phraseBlock.id)
        }
        
        // 实战使用 3 次 → distilled
        for _ in 0..<3 {
            await manager.recordRealWorldUsage(
                phraseBlockID: phraseBlock.id,
                sessionID: UUID().uuidString
            )
        }
        
        let result = await manager.getPhraseBlock(id: phraseBlock.id)
        #expect(result?.status == .distilled)
        #expect(result?.realWorldUsageCount == 3)
    }
}
```

### 2.2 Actor 测试

```swift
@Suite("Practice Room Service Tests")
struct PracticeRoomServiceTests {
    var service: PracticeRoomService!
    var mockVoiceSession: MockVoiceSessionService!
    var mockPhraseBlockManager: MockPhraseBlockManager!
    
    init() async throws {
        mockVoiceSession = MockVoiceSessionService()
        mockPhraseBlockManager = MockPhraseBlockManager()
        
        service = PracticeRoomService(
            voiceSession: mockVoiceSession,
            phraseBlockManager: mockPhraseBlockManager,
            materialProcessor: MockMaterialProcessor(),
            instantFeedback: MockInstantFeedbackDetector(),
            stallRescue: MockStallRescueManager(),
            reviewEngine: MockReviewEngine()
        )
    }
    
    @Test("Start session initializes correctly")
    func testStartSession() async throws {
        let sessionID = try await service.startSession(
            material: nil,
            sceneType: .demo,
            sessionType: .standard,
            userID: "test-user"
        )
        
        #expect(sessionID != nil)
        #expect(mockVoiceSession.isConnected == true)
    }
    
    @Test("Session emits events correctly")
    func testSessionEvents() async throws {
        try await service.startSession(
            material: nil,
            sceneType: .demo,
            sessionType: .standard,
            userID: "test-user"
        )
        
        var receivedEvents: [PracticeRoomEvent] = []
        
        let eventTask = Task {
            for await event in await service.events {
                receivedEvents.append(event)
                if receivedEvents.count >= 2 {
                    break
                }
            }
        }
        
        // 模拟用户说话
        await mockVoiceSession.simulateUserUtterance("Hello")
        
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        
        eventTask.cancel()
        
        #expect(receivedEvents.count >= 1)
        #expect(receivedEvents.contains { 
            if case .userSpoke = $0 { return true }
            return false
        })
    }
}
```

### 2.3 Pure Logic 测试

```swift
@Suite("Stall Detection Tests")
struct StallDetectionTests {
    @Test("Detects silence duration correctly")
    func testSilenceDetection() {
        let detector = SilenceDetector(threshold: 3.0)
        
        let now = Date()
        detector.recordSpeech(at: now)
        
        #expect(detector.silenceDuration(at: now.addingTimeInterval(2.0)) == 2.0)
        #expect(detector.silenceDuration(at: now.addingTimeInterval(3.5)) == 3.5)
        #expect(detector.isStalled(at: now.addingTimeInterval(3.5)) == true)
    }
    
    @Test("Resets on new speech")
    func testSilenceReset() {
        let detector = SilenceDetector(threshold: 3.0)
        
        let now = Date()
        detector.recordSpeech(at: now)
        
        #expect(detector.silenceDuration(at: now.addingTimeInterval(2.0)) == 2.0)
        
        detector.recordSpeech(at: now.addingTimeInterval(2.5))
        
        #expect(detector.silenceDuration(at: now.addingTimeInterval(3.0)) == 0.5)
        #expect(detector.isStalled(at: now.addingTimeInterval(3.0)) == false)
    }
}
```

---

## 三、集成测试

### 3.1 Actor 交互测试

```swift
@Suite("Instant Feedback Integration Tests")
struct InstantFeedbackIntegrationTests {
    var detector: InstantFeedbackDetector!
    var phraseBlockManager: PhraseBlockManager!
    var persistence: PersistenceService!
    
    init() async throws {
        persistence = PersistenceService()
        phraseBlockManager = PhraseBlockManager(persistence: persistence)
        detector = InstantFeedbackDetector(
            phraseBlockManager: phraseBlockManager,
            embeddingService: EmbeddingService(),
            llmVerifier: LLMVerifier()
        )
    }
    
    @Test("Detects phrase match in real utterance")
    func testRealPhraseDetection() async throws {
        // 准备话术块
        let phraseBlock = try await phraseBlockManager.createPhraseBlock(
            userID: "test-user",
            englishPhrase: "I think the main risk here is data consistency",
            chineseTranslation: "我认为主要风险是数据一致性",
            sceneTags: ["design_review"],
            source: .userCreated
        )
        
        // 激活检测
        await detector.activatePhraseBlocks([phraseBlock])
        
        // 模拟用户说话（相似表达）
        let utterance = Utterance(
            id: UUID(),
            speaker: .user,
            transcript: "I believe the primary risk is maintaining data consistency",
            timestamp: Date()
        )
        
        let matches = await detector.detectMatches(in: utterance)
        
        #expect(matches.count >= 1)
        #expect(matches.first?.phraseBlockID == phraseBlock.id)
        #expect(matches.first?.confidence >= 0.85)
    }
}
```

### 3.2 WebSocket 集成测试

```swift
@Suite("WebSocket Integration Tests")
struct WebSocketIntegrationTests {
    var transport: WebSocketTransport!
    
    init() async throws {
        transport = WebSocketTransport(
            url: URL(string: "wss://test.example.com/voice")!,
            authToken: "test-token"
        )
    }
    
    @Test("Connects and receives messages")
    func testWebSocketConnection() async throws {
        try await transport.connect()
        
        #expect(await transport.isConnected == true)
        
        var receivedMessages: [WebSocketMessage] = []
        
        let receiveTask = Task {
            for await message in await transport.messages {
                receivedMessages.append(message)
                if receivedMessages.count >= 1 {
                    break
                }
            }
        }
        
        // 发送测试消息
        try await transport.send(.text("ping"))
        
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s
        
        receiveTask.cancel()
        
        #expect(receivedMessages.count >= 1)
    }
}
```

---

## 四、UI 测试

### 4.1 SwiftUI Preview 测试

```swift
#Preview("Practice Room - Active Session") {
    let mockService = MockPracticeRoomService()
    mockService.sessionState = .active
    
    let viewModel = PracticeRoomViewModel(
        practiceRoomService: mockService,
        phraseBlockManager: MockPhraseBlockManager()
    )
    
    return PracticeRoomView(viewModel: viewModel)
}

#Preview("Practice Room - Phrase Match") {
    let mockService = MockPracticeRoomService()
    
    let viewModel = PracticeRoomViewModel(
        practiceRoomService: mockService,
        phraseBlockManager: MockPhraseBlockManager()
    )
    
    viewModel.matchedPhraseBlocks = [
        PhraseMatchPresentation(
            id: UUID(),
            phraseBlockID: UUID(),
            englishPhrase: "Let's schedule a follow-up",
            confidence: 0.92
        )
    ]
    
    return PracticeRoomView(viewModel: viewModel)
}
```

### 4.2 UI 自动化测试

```swift
import XCTest

final class PracticeRoomUITests: XCTestCase {
    var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }
    
    func testStartSession() {
        // 导航到 Practice Room
        app.buttons["Practice Room"].tap()
        
        // 点击开始
        app.buttons["Start Practice"].tap()
        
        // 验证会话已开始
        XCTAssertTrue(app.staticTexts["Session Active"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["End Session"].exists)
    }
    
    func testPhraseMatchNotification() {
        // 开始会话
        app.buttons["Practice Room"].tap()
        app.buttons["Start Practice"].tap()
        
        // 等待话术块匹配通知
        let matchBadge = app.staticTexts["Phrase Matched"]
        
        // 注入模拟匹配事件
        app.buttons["Simulate Phrase Match"].tap()
        
        XCTAssertTrue(matchBadge.waitForExistence(timeout: 2))
        
        // 验证 3 秒后消失
        sleep(4)
        XCTAssertFalse(matchBadge.exists)
    }
}
```

---

## 五、性能测试

### 5.1 延迟测试

```swift
@Suite("Performance Tests", .tags(.performance))
struct PerformanceTests {
    @Test("First response latency P90 ≤ 1.5s", .timeLimit(.seconds(5)))
    func testFirstResponseLatency() async throws {
        let service = PracticeRoomService(/* real dependencies */)
        
        var latencies: [TimeInterval] = []
        
        // 运行 100 次测试
        for _ in 0..<100 {
            try await service.startSession(
                material: nil,
                sceneType: .demo,
                sessionType: .standard,
                userID: "perf-test-user"
            )
            
            let startTime = Date()
            
            // 模拟用户说话
            await service.processUserUtterance("Hello, how are you?")
            
            // 等待首个 AI 音频块
            var firstResponseTime: TimeInterval?
            for await event in await service.events {
                if case .aiAudioChunk = event {
                    firstResponseTime = Date().timeIntervalSince(startTime)
                    break
                }
            }
            
            if let latency = firstResponseTime {
                latencies.append(latency)
            }
            
            try await service.endSession()
        }
        
        // 计算 P90
        latencies.sort()
        let p90Index = Int(Double(latencies.count) * 0.9)
        let p90Latency = latencies[p90Index]
        
        #expect(p90Latency <= 1.5, "P90 latency \(p90Latency)s exceeds 1.5s target")
    }
    
    @Test("Instant feedback detection ≤ 500ms", .timeLimit(.seconds(2)))
    func testInstantFeedbackLatency() async throws {
        let detector = InstantFeedbackDetector(/* ... */)
        
        // 准备话术块
        let phraseBlocks = [/* ... */]
        await detector.activatePhraseBlocks(phraseBlocks)
        
        var latencies: [TimeInterval] = []
        
        for _ in 0..<50 {
            let utterance = generateTestUtterance()
            let startTime = Date()
            
            let matches = await detector.detectMatches(in: utterance)
            
            let latency = Date().timeIntervalSince(startTime)
            latencies.append(latency)
        }
        
        let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
        
        #expect(avgLatency <= 0.5, "Avg detection latency \(avgLatency)s exceeds 500ms target")
    }
}
```

### 5.2 内存测试

```swift
@Test("Memory usage under load")
func testMemoryUsage() async throws {
    let monitor = MemoryMonitor()
    await monitor.startMonitoring()
    
    let service = PracticeRoomService(/* ... */)
    
    // 模拟 10 分钟会话
    try await service.startSession(/* ... */)
    
    for _ in 0..<100 {
        await service.processUserUtterance(generateRandomUtterance())
        try? await Task.sleep(nanoseconds: 6_000_000_000)  // 6s
    }
    
    try await service.endSession()
    
    let peakUsage = await monitor.getPeakUsage()
    let avgUsage = await monitor.getAverageUsage()
    
    #expect(peakUsage <= 150 * 1024 * 1024, "Peak memory \(peakUsage / 1024 / 1024)MB exceeds 150MB")
    #expect(avgUsage <= 100 * 1024 * 1024, "Avg memory \(avgUsage / 1024 / 1024)MB exceeds 100MB")
}
```

---

## 六、Mock 实现

### 6.1 Mock Services

```swift
actor MockVoiceSessionService: VoiceSessionServiceProtocol {
    var isConnected = false
    private var eventContinuation: AsyncStream<VoiceSessionEvent>.Continuation?
    
    lazy var events: AsyncStream<VoiceSessionEvent> = {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }()
    
    func connect() async throws {
        isConnected = true
        eventContinuation?.yield(.connected)
    }
    
    func disconnect() async {
        isConnected = false
        eventContinuation?.yield(.disconnected)
    }
    
    func sendAudio(_ data: Data) async throws {
        // Simulate processing
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    }
    
    func simulateUserUtterance(_ text: String) {
        let utterance = Utterance(
            id: UUID(),
            speaker: .user,
            transcript: text,
            timestamp: Date()
        )
        eventContinuation?.yield(.utteranceReceived(utterance))
    }
}

actor MockPhraseBlockManager: PhraseBlockManagerProtocol {
    var phraseBlocks: [PhraseBlock] = []
    
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
        phraseBlocks.append(phraseBlock)
        return phraseBlock
    }
    
    func getPhraseBlock(id: UUID) async -> PhraseBlock? {
        phraseBlocks.first { $0.id == id }
    }
    
    func getActivePhraseBlocks(userID: String) async -> [PhraseBlock] {
        phraseBlocks.filter { $0.userID == userID }
    }
}
```

---

## 七、CI/CD 集成

### 7.1 GitHub Actions 配置

```yaml
name: iOS Tests

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  test:
    runs-on: macos-14
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Select Xcode
      run: sudo xcode-select -s /Applications/Xcode_15.2.app
    
    - name: Run Tests
      run: |
        xcodebuild test \
          -scheme FluentWork \
          -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.2' \
          -resultBundlePath TestResults.xcresult \
          -enableCodeCoverage YES
    
    - name: Generate Coverage Report
      run: |
        xcrun xccov view --report --json TestResults.xcresult > coverage.json
    
    - name: Upload Coverage
      uses: codecov/codecov-action@v3
      with:
        files: ./coverage.json
    
    - name: Performance Tests
      run: |
        xcodebuild test \
          -scheme FluentWork \
          -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
          -only-testing:FluentWorkTests/PerformanceTests
```

---

## 八、质量门禁

### 8.1 自动化检查

```swift
// pre-commit hook
#!/bin/sh

echo "Running tests..."
xcodebuild test -scheme FluentWork -destination 'platform=iOS Simulator,name=iPhone 15 Pro' || exit 1

echo "Checking code coverage..."
COVERAGE=$(xcrun xccov view --report --json TestResults.xcresult | jq '.lineCoverage')
THRESHOLD=0.80

if (( $(echo "$COVERAGE < $THRESHOLD" | bc -l) )); then
    echo "❌ Coverage $COVERAGE is below threshold $THRESHOLD"
    exit 1
fi

echo "✅ All checks passed"
```

### 8.2 Review Checklist

```markdown
## PR Review Checklist

### 功能
- [ ] 新功能有对应的单元测试
- [ ] 新功能有对应的集成测试
- [ ] 边界情况已覆盖

### 性能
- [ ] 没有引入明显的性能退化
- [ ] 异步操作使用正确的优先级
- [ ] 内存泄漏检查通过

### 代码质量
- [ ] 遵循项目代码规范
- [ ] 变量和函数命名清晰
- [ ] 复杂逻辑有注释说明

### 测试
- [ ] 所有测试通过
- [ ] 代码覆盖率 ≥ 80%
- [ ] 性能测试通过（如有）
```

---

**最后更新**: 2026-09-21  
**下一文档**: [11_implementation_roadmap.md](11_implementation_roadmap.md)
