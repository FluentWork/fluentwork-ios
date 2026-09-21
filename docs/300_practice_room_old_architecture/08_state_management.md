# 状态管理与生命周期

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 8  
**状态**: 设计阶段

---

## 一、架构概览

Practice Room 采用单向数据流架构，ViewModel 作为 UI 和业务逻辑的桥梁。

```
┌─────────────────────────────────────┐
│         View (SwiftUI)              │
│  - PracticeRoomView                 │
│  - ReviewView                       │
└──────────┬──────────────────────────┘
           │ user actions
           ▼
┌─────────────────────────────────────┐
│    ViewModel (@MainActor)           │
│  - @Published state                 │
│  - async actions                    │
└──────────┬──────────────────────────┘
           │ commands
           ▼
┌─────────────────────────────────────┐
│   Domain Layer (Actors)             │
│  - PracticeRoomService              │
│  - PhraseBlockManager               │
└──────────┬──────────────────────────┘
           │ events
           ▼
┌─────────────────────────────────────┐
│   Infrastructure Layer              │
│  - VoiceSessionService              │
│  - PersistenceService               │
└─────────────────────────────────────┘
```

---

## 二、ViewModel 设计

### 2.1 PracticeRoomViewModel

```swift
@MainActor
class PracticeRoomViewModel: ObservableObject {
    // MARK: - Published State
    
    @Published var sessionState: SessionState = .idle
    @Published var currentTranscript: [TurnPresentation] = []
    @Published var liveTranscriptText: String = ""
    @Published var isAISpeaking: Bool = false
    @Published var matchedPhraseBlocks: [PhraseMatchPresentation] = []
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    
    // MARK: - Dependencies
    
    private let practiceRoomService: PracticeRoomService
    private let phraseBlockManager: PhraseBlockManager
    
    // MARK: - Subscriptions
    
    private var eventSubscription: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(practiceRoomService: PracticeRoomService, phraseBlockManager: PhraseBlockManager) {
        self.practiceRoomService = practiceRoomService
        self.phraseBlockManager = phraseBlockManager
        subscribeToEvents()
    }
    
    deinit {
        eventSubscription?.cancel()
    }
    
    // MARK: - Actions
    
    func startSession(material: Material?, sceneType: ScenarioType) async {
        do {
            sessionState = .preparing
            
            let sessionID = try await practiceRoomService.startSession(
                material: material,
                sceneType: sceneType,
                sessionType: .standard,
                userID: getCurrentUserID()
            )
            
            sessionState = .active
            
        } catch {
            handleError(error)
        }
    }
    
    func endSession() async {
        do {
            sessionState = .ending
            let completedSession = try await practiceRoomService.endSession()
            sessionState = .completed
            
            // 导航到回顾页
            // NavigationCoordinator.shared.navigate(to: .review(completedSession))
            
        } catch {
            handleError(error)
        }
    }
    
    func pauseSession() async {
        do {
            try await practiceRoomService.pauseSession()
            sessionState = .paused
        } catch {
            handleError(error)
        }
    }
    
    func resumeSession() async {
        do {
            try await practiceRoomService.resumeSession()
            sessionState = .active
        } catch {
            handleError(error)
        }
    }
    
    func abandonSession() async {
        await practiceRoomService.abandonSession()
        sessionState = .idle
        currentTranscript.removeAll()
        liveTranscriptText = ""
    }
    
    // MARK: - Event Handling
    
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
            appendTurn(from: utterance)
            
        case .aiSpoke(let utterance):
            appendTurn(from: utterance)
            isAISpeaking = false
            
        case .aiSpeaking:
            isAISpeaking = true
            
        case .transcriptUpdate(let text):
            liveTranscriptText = text
            
        case .phraseMatched(let match):
            showPhraseMatchBadge(match)
            
        case .sessionEnded:
            sessionState = .completed
            
        case .sessionAbandoned:
            sessionState = .idle
            
        case .error(let error):
            handleError(error)
        
        default:
            break
        }
    }
    
    private func appendTurn(from utterance: Utterance) {
        let presentation = TurnPresentation(
            id: utterance.id,
            speaker: utterance.speaker,
            text: utterance.transcript,
            timestamp: utterance.timestamp
        )
        currentTranscript.append(presentation)
    }
    
    private func showPhraseMatchBadge(_ match: PhraseMatch) {
        let presentation = PhraseMatchPresentation(
            id: UUID(),
            phraseBlockID: match.phraseBlockID,
            englishPhrase: match.phraseBlock.englishPhrase,
            confidence: match.confidence
        )
        
        matchedPhraseBlocks.append(presentation)
        
        // 3 秒后自动移除
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            matchedPhraseBlocks.removeAll { $0.id == presentation.id }
        }
    }
    
    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
    
    private func getCurrentUserID() -> String {
        "user-123"  // TODO: 从用户管理服务获取
    }
}

// MARK: - Presentation Models

struct TurnPresentation: Identifiable {
    let id: UUID
    let speaker: Speaker
    let text: String
    let timestamp: Date
}

struct PhraseMatchPresentation: Identifiable {
    let id: UUID
    let phraseBlockID: UUID
    let englishPhrase: String
    let confidence: Double
}

enum SessionState {
    case idle
    case preparing
    case active
    case paused
    case ending
    case completed
}
```

### 2.2 PhraseBlockLibraryViewModel

```swift
@MainActor
class PhraseBlockLibraryViewModel: ObservableObject {
    @Published var phraseBlocks: [PhraseBlock] = []
    @Published var filteredPhraseBlocks: [PhraseBlock] = []
    @Published var selectedTags: Set<String> = []
    @Published var searchQuery: String = ""
    @Published var isLoading: Bool = false
    
    private let phraseBlockManager: PhraseBlockManager
    
    init(phraseBlockManager: PhraseBlockManager) {
        self.phraseBlockManager = phraseBlockManager
    }
    
    func loadPhraseBlocks() async {
        isLoading = true
        defer { isLoading = false }
        
        phraseBlocks = await phraseBlockManager.getActivePhraseBlocks(userID: getCurrentUserID())
        applyFilters()
    }
    
    func search(_ query: String) async {
        searchQuery = query
        
        if query.isEmpty {
            applyFilters()
        } else {
            isLoading = true
            filteredPhraseBlocks = await phraseBlockManager.searchPhraseBlocks(
                userID: getCurrentUserID(),
                query: query,
                tags: selectedTags.isEmpty ? nil : Array(selectedTags)
            )
            isLoading = false
        }
    }
    
    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
        applyFilters()
    }
    
    func deletePhraseBlock(_ phraseBlock: PhraseBlock) async {
        do {
            try await phraseBlockManager.deletePhraseBlock(id: phraseBlock.id)
            phraseBlocks.removeAll { $0.id == phraseBlock.id }
            applyFilters()
        } catch {
            // Handle error
        }
    }
    
    private func applyFilters() {
        var filtered = phraseBlocks
        
        if !selectedTags.isEmpty {
            filtered = filtered.filter { phraseBlock in
                !Set(phraseBlock.sceneTags).isDisjoint(with: selectedTags)
            }
        }
        
        filteredPhraseBlocks = filtered
    }
    
    private func getCurrentUserID() -> String {
        "user-123"
    }
}
```

---

## 三、生命周期管理

### 3.1 会话生命周期

```swift
actor SessionLifecycleManager {
    private var currentSession: SessionContext?
    
    func beginSession(_ session: SessionContext) {
        currentSession = session
        
        // 配置音频会话
        configureAudioSession()
        
        // 禁用屏幕自动锁定
        disableIdleTimer()
    }
    
    func endSession() {
        guard let session = currentSession else { return }
        
        // 保存会话数据
        saveSessionData(session)
        
        // 恢复音频会话
        restoreAudioSession()
        
        // 恢复屏幕自动锁定
        enableIdleTimer()
        
        currentSession = nil
    }
    
    func handleInterruption(_ interruption: AudioInterruption) async {
        switch interruption {
        case .began:
            await pauseSession()
        case .ended(shouldResume: let shouldResume):
            if shouldResume {
                await resumeSession()
            }
        }
    }
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try? session.setActive(true)
    }
    
    private func restoreAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
    }
    
    private func disableIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    private func enableIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    private func saveSessionData(_ session: SessionContext) {
        // TODO: 持久化会话数据
    }
    
    private func pauseSession() async {
        // TODO: 暂停对话
    }
    
    private func resumeSession() async {
        // TODO: 恢复对话
    }
}

struct SessionContext {
    let sessionID: UUID
    let startTime: Date
    var state: SessionState
}
```

### 3.2 应用生命周期集成

```swift
@main
struct FluentWorkApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    handleScenePhaseChange(from: oldPhase, to: newPhase)
                }
        }
    }
    
    private func handleScenePhaseChange(from old: ScenePhase, to new: ScenePhase) {
        switch new {
        case .active:
            appState.onAppActive()
        case .inactive:
            appState.onAppInactive()
        case .background:
            appState.onAppBackground()
        @unknown default:
            break
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var hasActivePracticeSession = false
    
    func onAppActive() {
        // 恢复音频会话
    }
    
    func onAppInactive() {
        // 准备进入后台
    }
    
    func onAppBackground() {
        // 如果有活跃会话，显示通知提醒用户回来
        if hasActivePracticeSession {
            scheduleResumeNotification()
        }
    }
    
    private func scheduleResumeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Practice Session Active"
        content.body = "Your practice session is waiting for you"
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        let request = UNNotificationRequest(identifier: "resume-session", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request)
    }
}
```

---

## 四、数据同步策略

### 4.1 本地优先架构

```swift
actor DataSyncManager {
    private let persistence: PersistenceService
    private let apiService: PracticeRoomAPIService
    
    private var syncQueue: [SyncOperation] = []
    private var isSyncing = false
    
    func syncPhraseBlock(_ phraseBlock: PhraseBlock) async {
        // 1. 立即保存到本地
        try? await persistence.save(phraseBlock)
        
        // 2. 添加到同步队列
        let operation = SyncOperation(
            type: .createOrUpdate,
            entity: .phraseBlock(phraseBlock),
            timestamp: Date()
        )
        syncQueue.append(operation)
        
        // 3. 触发异步同步
        Task {
            await performSync()
        }
    }
    
    func syncSession(_ session: PracticeSession) async {
        try? await persistence.save(session)
        
        let operation = SyncOperation(
            type: .createOrUpdate,
            entity: .session(session),
            timestamp: Date()
        )
        syncQueue.append(operation)
        
        Task {
            await performSync()
        }
    }
    
    private func performSync() async {
        guard !isSyncing, !syncQueue.isEmpty else { return }
        
        isSyncing = true
        defer { isSyncing = false }
        
        while !syncQueue.isEmpty {
            let operation = syncQueue.removeFirst()
            
            do {
                try await uploadOperation(operation)
            } catch {
                // 同步失败，放回队列
                syncQueue.insert(operation, at: 0)
                Logger.error("Sync failed: \(error)")
                
                // 等待后重试
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    
    private func uploadOperation(_ operation: SyncOperation) async throws {
        switch operation.entity {
        case .phraseBlock(let phraseBlock):
            try await apiService.syncPhraseBlock(phraseBlock)
        case .session(let session):
            try await apiService.syncSession(session)
        }
    }
}

struct SyncOperation {
    let type: SyncType
    let entity: SyncEntity
    let timestamp: Date
}

enum SyncType {
    case createOrUpdate
    case delete
}

enum SyncEntity {
    case phraseBlock(PhraseBlock)
    case session(PracticeSession)
}
```

---

## 五、内存管理

### 5.1 缓存策略

```swift
actor MemoryManager {
    private var transcriptCache: [UUID: [Turn]] = [:]
    private var audioCache: [UUID: Data] = [:]
    
    private let maxTranscriptCacheSize = 10  // 最多缓存 10 个会话
    private let maxAudioCacheSize = 50 * 1024 * 1024  // 50 MB
    
    func cacheTranscript(_ transcript: [Turn], for sessionID: UUID) {
        if transcriptCache.count >= maxTranscriptCacheSize {
            evictOldestTranscript()
        }
        transcriptCache[sessionID] = transcript
    }
    
    func cacheAudio(_ data: Data, for sessionID: UUID) {
        let currentSize = audioCache.values.reduce(0) { $0 + $1.count }
        
        if currentSize + data.count > maxAudioCacheSize {
            clearAudioCache()
        }
        
        audioCache[sessionID] = data
    }
    
    func clearMemory() {
        transcriptCache.removeAll()
        audioCache.removeAll()
    }
    
    private func evictOldestTranscript() {
        guard let oldestKey = transcriptCache.keys.first else { return }
        transcriptCache.removeValue(forKey: oldestKey)
    }
    
    private func clearAudioCache() {
        audioCache.removeAll()
    }
}
```

---

## 六、测试策略

```swift
@Test
func testViewModelStateTransitions() async {
    let mockService = MockPracticeRoomService()
    let viewModel = PracticeRoomViewModel(practiceRoomService: mockService, phraseBlockManager: mockManager)
    
    // 初始状态
    #expect(viewModel.sessionState == .idle)
    
    // 开始会话
    await viewModel.startSession(material: nil, sceneType: .demo)
    #expect(viewModel.sessionState == .active)
    
    // 结束会话
    await viewModel.endSession()
    #expect(viewModel.sessionState == .completed)
}
```

---

**最后更新**: 2026-09-21  
**下一文档**: [09_performance_optimization.md](09_performance_optimization.md)
