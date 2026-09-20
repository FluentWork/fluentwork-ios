# 并发模型与线程安全

**日期**: 2026-09-21  
**目标**: 定义系统的并发模型、Actor 隔离策略、线程约束，确保数据竞争的完全消除

---

## 一、并发模型概述

### 1.1 Swift Concurrency 核心概念

iOS 应用采用 **Swift Concurrency** 作为并发基础：

- **async/await**: 异步编程基础语法
- **Actor**: 数据隔离与串行化访问
- **Task**: 并发执行单元
- **AsyncStream**: 异步事件流
- **@MainActor**: UI 线程隔离

### 1.2 线程模型

```
┌─────────────────────────────────────────────────────────┐
│                     Main Thread                          │
│  - SwiftUI Views                                        │
│  - ViewModels (@MainActor)                              │
│  - UI Updates                                           │
└────────────────────┬────────────────────────────────────┘
                     │ @MainActor boundary
                     │
┌────────────────────▼────────────────────────────────────┐
│                 Actor Executors                          │
│  - VoiceSessionService (actor)                          │
│  - WebSocketTransport (actor)                           │
│  - AudioEngine (actor)                                  │
│  - StateManager (actor)                                 │
└────────────────────┬────────────────────────────────────┘
                     │ Actor isolation
                     │
┌────────────────────▼────────────────────────────────────┐
│              Real-Time Audio Thread                      │
│  - AVAudioEngine callbacks                              │
│  - 不能加锁                                              │
│  - 不能分配内存（最小化）                                 │
└─────────────────────────────────────────────────────────┘
```

---

## 二、Actor 隔离策略

### 2.1 核心 Actor 设计

```swift
// MARK: - Voice Session Service (业务层)

actor VoiceSessionService {
    // 状态隔离
    private let stateMachine: VoiceSessionStateMachine
    private let transport: WebSocketTransport
    private let audioEngine: AudioEngine
    
    // 事件流
    private let eventStream: AsyncStream<VoiceSessionEvent>
    private let eventContinuation: AsyncStream<VoiceSessionEvent>.Continuation
    
    init(
        transport: WebSocketTransport,
        audioEngine: AudioEngine
    ) {
        self.transport = transport
        self.audioEngine = audioEngine
        self.stateMachine = VoiceSessionStateMachine()
        
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream()
    }
    
    // 所有公开方法都是 async，确保串行执行
    func connect() async throws {
        try await stateMachine.connect()
        try await transport.connect()
        eventContinuation.yield(.connected)
    }
    
    func startRecording() async throws -> String {
        let turnID = try await stateMachine.startRecording()
        try await audioEngine.startCapture { [weak self] audioData in
            guard let self = self else { return }
            try await self.handleAudioData(audioData, turnID: turnID)
        }
        eventContinuation.yield(.recordingStarted(turnID: turnID))
        return turnID
    }
    
    func stopRecording(turnID: String) async throws {
        try await audioEngine.stopCapture()
        try await stateMachine.stopRecording(turnID: turnID)
        eventContinuation.yield(.recordingStopped(turnID: turnID))
    }
    
    // 私有方法也是 async，Actor 自动串行化
    private func handleAudioData(_ data: Data, turnID: String) async throws {
        try await transport.sendAudio(data, turnID: turnID)
    }
    
    // 事件订阅（可以从多个地方调用）
    func events() -> AsyncStream<VoiceSessionEvent> {
        eventStream
    }
}

enum VoiceSessionEvent {
    case connected
    case disconnected
    case recordingStarted(turnID: String)
    case recordingStopped(turnID: String)
    case textReceived(turnID: String, text: String)
    case audioReceived(turnID: String, data: Data)
    case turnCompleted(turnID: String)
    case error(Error)
}
```

### 2.2 Actor 隔离规则

**规则 1: 状态完全隔离**

```swift
actor StateContainer {
    // ✅ 正确：状态在 actor 内部
    private var state: SessionState = .idle
    private var turnStates: [String: TurnState] = [:]
    
    func updateState(_ newState: SessionState) {
        state = newState  // 无需加锁，Actor 自动串行化
    }
    
    func getState() -> SessionState {
        state  // 读取也是串行的
    }
}
```

**规则 2: 避免共享可变状态**

```swift
// ❌ 错误：跨 Actor 共享可变状态
class SharedState {
    var count: Int = 0  // 数据竞争！
}

actor ActorA {
    let shared: SharedState
    func increment() {
        shared.count += 1  // 竞争条件
    }
}

actor ActorB {
    let shared: SharedState
    func decrement() {
        shared.count -= 1  // 竞争条件
    }
}

// ✅ 正确：每个 Actor 独立状态，通过消息传递通信
actor ActorA {
    private var count: Int = 0
    
    func increment() -> Int {
        count += 1
        return count
    }
}

actor ActorB {
    private let actorA: ActorA
    
    func syncWithA() async {
        let currentCount = await actorA.increment()
        // 使用返回值，不共享状态
    }
}
```

**规则 3: Sendable 约束**

```swift
// 只有 Sendable 类型可以跨 Actor 传递
actor AudioProcessor {
    // ✅ Data 是 Sendable
    func process(_ data: Data) async {
        // ...
    }
    
    // ❌ NSMutableData 不是 Sendable
    // func process(_ data: NSMutableData) async { ... }
}

// 自定义类型标记为 Sendable
struct AudioFrame: Sendable {
    let sequence: Int
    let data: Data
    let timestamp: Double
}
```

---

## 三、主线程隔离（@MainActor）

### 3.1 ViewModel 设计

```swift
@MainActor
class ConversationViewModel: ObservableObject {
    // 所有属性访问都在主线程
    @Published var turns: [Turn] = []
    @Published var sessionState: SessionState = .idle
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    
    private let service: VoiceSessionService
    private var eventTask: Task<Void, Never>?
    
    init(service: VoiceSessionService) {
        self.service = service
    }
    
    // 所有方法都在主线程
    func connect() async {
        do {
            try await service.connect()
            sessionState = .connected
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func startRecording() async {
        isRecording = true
        
        do {
            let turnID = try await service.startRecording()
            let turn = Turn(id: turnID, userText: "", aiText: "")
            turns.append(turn)
        } catch {
            errorMessage = error.localizedDescription
            isRecording = false
        }
    }
    
    func stopRecording() async {
        isRecording = false
        
        guard let currentTurn = turns.last else { return }
        
        do {
            try await service.stopRecording(turnID: currentTurn.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // 订阅服务事件
    func startListening() {
        eventTask = Task { @MainActor in
            for await event in await service.events() {
                handleEvent(event)
            }
        }
    }
    
    func stopListening() {
        eventTask?.cancel()
        eventTask = nil
    }
    
    // 事件处理（已在主线程）
    private func handleEvent(_ event: VoiceSessionEvent) {
        switch event {
        case .textReceived(let turnID, let text):
            if let index = turns.firstIndex(where: { $0.id == turnID }) {
                turns[index].aiText = text
            }
            
        case .error(let error):
            errorMessage = error.localizedDescription
            
        default:
            break
        }
    }
}

struct Turn: Identifiable {
    let id: String
    var userText: String
    var aiText: String
}
```

### 3.2 跨边界调用

```swift
// ViewModel (MainActor) → Service (Actor)
@MainActor
class MyViewModel: ObservableObject {
    let service: VoiceSessionService
    
    func doSomething() async {
        // 自动切换到 service 的 actor executor
        try? await service.connect()
        
        // 回到主线程
        self.updateUI()
    }
    
    private func updateUI() {
        // 在主线程执行
    }
}

// Service (Actor) → ViewModel (MainActor)
actor MyService {
    func notifyUI(viewModel: MyViewModel) async {
        // 自动切换到主线程
        await viewModel.updateSomething()
    }
}

extension MyViewModel {
    func updateSomething() {
        // 自动在主线程执行（因为 MyViewModel 是 @MainActor）
    }
}
```

---

## 四、音频线程约束

### 4.1 实时音频线程规则

AVAudioEngine 的 `installTap` 回调运行在**实时音频线程**，必须遵守严格约束：

**禁止操作**:
- ❌ 加锁（Mutex, Semaphore）
- ❌ 内存分配（尽量避免）
- ❌ 调用 Objective-C 方法
- ❌ 调用可能阻塞的系统调用
- ❌ 触发 Swift Concurrency（await）

**允许操作**:
- ✅ 无锁数据结构读写
- ✅ 预分配缓冲区复制
- ✅ 简单计算
- ✅ 发送到其他线程（通过无锁队列）

### 4.2 音频数据传递方案

**方案 1: 无锁环形缓冲区（推荐）**

```swift
// 无锁环形缓冲区（基于 Atomic）
final class LockFreeRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }
    
    deinit {
        buffer.deallocate()
    }
    
    // 从音频线程写入（无锁）
    func write(_ data: UnsafePointer<UInt8>, count: Int) -> Bool {
        let currentWrite = writeIndex.load(ordering: .relaxed)
        let currentRead = readIndex.load(ordering: .acquiring)
        
        let available = (currentRead + capacity - currentWrite - 1) % capacity
        guard count <= available else {
            return false  // 缓冲区满
        }
        
        // 写入数据（可能分两段）
        let end = currentWrite + count
        if end <= capacity {
            buffer.advanced(by: currentWrite).update(from: data, count: count)
        } else {
            let firstPart = capacity - currentWrite
            buffer.advanced(by: currentWrite).update(from: data, count: firstPart)
            buffer.update(from: data.advanced(by: firstPart), count: count - firstPart)
        }
        
        writeIndex.store((currentWrite + count) % capacity, ordering: .releasing)
        return true
    }
    
    // 从 Actor 线程读取（无锁）
    func read(into: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        let currentRead = readIndex.load(ordering: .relaxed)
        let currentWrite = writeIndex.load(ordering: .acquiring)
        
        let available = (currentWrite + capacity - currentRead) % capacity
        let toRead = min(count, available)
        
        if toRead == 0 {
            return 0
        }
        
        // 读取数据（可能分两段）
        let end = currentRead + toRead
        if end <= capacity {
            into.update(from: buffer.advanced(by: currentRead), count: toRead)
        } else {
            let firstPart = capacity - currentRead
            into.update(from: buffer.advanced(by: currentRead), count: firstPart)
            into.advanced(by: firstPart).update(from: buffer, count: toRead - firstPart)
        }
        
        readIndex.store((currentRead + toRead) % capacity, ordering: .releasing)
        return toRead
    }
}
```

**方案 2: 双缓冲区（简单但有延迟）**

```swift
actor AudioCaptureManager {
    private var activeBuffer: Data = Data()
    private var standbyBuffer: Data = Data()
    private var isActiveBufferFull = false
    
    // 从音频线程调用（通过 Task.detached）
    nonisolated func audioCallback(_ buffer: AVAudioPCMBuffer) {
        // 在音频线程快速复制数据
        let data = extractData(from: buffer)
        
        // 异步发送到 Actor（不阻塞音频线程）
        Task.detached { [weak self] in
            await self?.enqueueAudio(data)
        }
    }
    
    private func enqueueAudio(_ data: Data) {
        activeBuffer.append(data)
        
        if activeBuffer.count >= 64000 {  // 4 秒
            isActiveBufferFull = true
        }
    }
    
    func swapBuffers() -> Data {
        guard isActiveBufferFull else {
            return Data()
        }
        
        swap(&activeBuffer, &standbyBuffer)
        activeBuffer.removeAll(keepingCapacity: true)
        isActiveBufferFull = false
        
        return standbyBuffer
    }
    
    private nonisolated func extractData(from buffer: AVAudioPCMBuffer) -> Data {
        // 快速提取数据（预分配）
        guard let channelData = buffer.int16ChannelData?[0] else {
            return Data()
        }
        
        let frameCount = Int(buffer.frameLength)
        return Data(bytes: channelData, count: frameCount * 2)
    }
}
```

### 4.3 音频回调实现

```swift
actor AudioEngineImpl: AudioEngine {
    private let engine = AVAudioEngine()
    private let ringBuffer = LockFreeRingBuffer(capacity: 320000)  // 20 秒
    private var processingTask: Task<Void, Never>?
    
    func startCapture(onAudioData: @escaping (Data) async -> Void) async throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        // installTap 回调运行在音频线程
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            // ⚠️ 这里是实时音频线程，不能加锁或 await
            guard let self = self else { return }
            
            guard let channelData = buffer.int16ChannelData?[0] else {
                return
            }
            
            let frameCount = Int(buffer.frameLength)
            
            // 写入无锁缓冲区
            _ = self.ringBuffer.write(
                UnsafeRawPointer(channelData).assumingMemoryBound(to: UInt8.self),
                count: frameCount * 2
            )
        }
        
        try engine.start()
        
        // 启动处理任务（从缓冲区读取并发送）
        processingTask = Task { [weak self] in
            guard let self = self else { return }
            
            var readBuffer = [UInt8](repeating: 0, count: 640)  // 20ms
            
            while !Task.isCancelled {
                // 从缓冲区读取
                let bytesRead = readBuffer.withUnsafeMutableBytes { ptr in
                    self.ringBuffer.read(
                        into: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        count: 640
                    )
                }
                
                if bytesRead > 0 {
                    let data = Data(readBuffer.prefix(bytesRead))
                    await onAudioData(data)
                } else {
                    // 缓冲区空，短暂休眠
                    try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
                }
            }
        }
    }
    
    func stopCapture() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processingTask?.cancel()
        processingTask = nil
    }
}
```

---

## 五、Task 管理

### 5.1 结构化并发

```swift
actor TaskCoordinator {
    private var activeTasks: [String: Task<Void, Never>] = [:]
    
    // 启动命名任务
    func start(name: String, operation: @escaping () async -> Void) {
        // 取消旧任务
        activeTasks[name]?.cancel()
        
        // 启动新任务
        activeTasks[name] = Task {
            await operation()
        }
    }
    
    // 取消特定任务
    func cancel(name: String) {
        activeTasks[name]?.cancel()
        activeTasks.removeValue(forKey: name)
    }
    
    // 取消所有任务
    func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }
    
    // 等待所有任务完成
    func waitAll() async {
        for (_, task) in activeTasks {
            await task.value
        }
    }
}

// 使用示例
actor VoiceSessionService {
    private let taskCoordinator = TaskCoordinator()
    
    func startSession() async {
        // 启动心跳任务
        await taskCoordinator.start(name: "heartbeat") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self.sendHeartbeat()
            }
        }
        
        // 启动音频处理任务
        await taskCoordinator.start(name: "audio") {
            await self.processAudioLoop()
        }
    }
    
    func stopSession() async {
        await taskCoordinator.cancelAll()
    }
}
```

### 5.2 Task 生命周期

```swift
actor SessionLifecycleManager {
    private var sessionTask: Task<Void, Error>?
    
    func start() async throws {
        // 确保没有旧任务
        sessionTask?.cancel()
        
        // 创建新任务
        sessionTask = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // 添加 WebSocket 任务
                group.addTask {
                    try await self.runWebSocket()
                }
                
                // 添加音频任务
                group.addTask {
                    try await self.runAudio()
                }
                
                // 添加状态监控任务
                group.addTask {
                    try await self.monitorState()
                }
                
                // 等待任何一个任务失败
                try await group.next()
                
                // 第一个任务失败时，取消其他所有任务
                group.cancelAll()
            }
        }
        
        try await sessionTask?.value
    }
    
    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
    }
    
    private func runWebSocket() async throws {
        // WebSocket 循环
    }
    
    private func runAudio() async throws {
        // 音频处理循环
    }
    
    private func monitorState() async throws {
        // 状态监控循环
    }
}
```

---

## 六、AsyncStream 事件流

### 6.1 事件发布

```swift
actor EventPublisher<Event> {
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    
    func publish(_ event: Event) {
        for (_, continuation) in continuations {
            continuation.yield(event)
        }
    }
    
    func subscribe() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        
        // 清理任务
        Task {
            for await _ in stream {
                // 空循环，仅为了检测 stream 结束
            }
            await unsubscribe(id)
        }
        
        return stream
    }
    
    private func unsubscribe(_ id: UUID) {
        continuations[id]?.finish()
        continuations.removeValue(forKey: id)
    }
    
    func finishAll() {
        for (_, continuation) in continuations {
            continuation.finish()
        }
        continuations.removeAll()
    }
}

// 使用示例
actor VoiceSessionService {
    private let eventPublisher = EventPublisher<VoiceSessionEvent>()
    
    func events() -> AsyncStream<VoiceSessionEvent> {
        await eventPublisher.subscribe()
    }
    
    private func notifyEvent(_ event: VoiceSessionEvent) async {
        await eventPublisher.publish(event)
    }
}
```

### 6.2 多播与过滤

```swift
extension AsyncStream {
    // 过滤事件
    func filter(_ predicate: @escaping (Element) -> Bool) -> AsyncStream<Element> {
        AsyncStream { continuation in
            Task {
                for await element in self {
                    if predicate(element) {
                        continuation.yield(element)
                    }
                }
                continuation.finish()
            }
        }
    }
    
    // 映射事件
    func map<T>(_ transform: @escaping (Element) -> T) -> AsyncStream<T> {
        AsyncStream<T> { continuation in
            Task {
                for await element in self {
                    continuation.yield(transform(element))
                }
                continuation.finish()
            }
        }
    }
}

// 使用示例
@MainActor
class ConversationViewModel: ObservableObject {
    func listenToErrors() async {
        let errorStream = await service.events()
            .filter { event in
                if case .error = event {
                    return true
                }
                return false
            }
        
        for await event in errorStream {
            if case .error(let error) = event {
                self.showError(error)
            }
        }
    }
}
```

---

## 七、死锁与竞争避免

### 7.1 常见陷阱

**陷阱 1: Actor 重入**

```swift
actor Counter {
    private var value: Int = 0
    
    // ❌ 危险：可能导致非预期行为
    func increment() async {
        value += 1
        await someAsyncOperation()  // 在这里，其他调用可能修改 value
        print(value)  // 可能不是我们期望的值
    }
    
    // ✅ 安全：一次性读取
    func safeIncrement() async {
        value += 1
        let snapshot = value  // 快照
        await someAsyncOperation()
        print(snapshot)  // 使用快照
    }
}
```

**陷阱 2: 循环等待**

```swift
// ❌ 死锁：A 等 B，B 等 A
actor ActorA {
    let actorB: ActorB
    
    func doSomething() async {
        await actorB.doSomethingElse()  // 等待 B
    }
}

actor ActorB {
    let actorA: ActorA
    
    func doSomethingElse() async {
        await actorA.doSomething()  // 等待 A → 死锁
    }
}

// ✅ 正确：单向依赖
actor ActorA {
    let actorB: ActorB
    
    func doSomething() async {
        await actorB.doSomethingElse()  // A 依赖 B
    }
}

actor ActorB {
    // B 不依赖 A
    func doSomethingElse() async {
        // ...
    }
}
```

### 7.2 避免策略

**策略 1: 最小化 await 点**

```swift
actor DataProcessor {
    private var cache: [String: Data] = [:]
    
    // ✅ 快速路径无 await
    func getData(key: String) async -> Data? {
        if let cached = cache[key] {
            return cached  // 快速返回
        }
        
        // 慢速路径
        let data = await fetchFromNetwork(key)
        cache[key] = data
        return data
    }
}
```

**策略 2: 批量操作**

```swift
actor BatchProcessor {
    func processItems(_ items: [Item]) async {
        // ✅ 一次性处理多个，减少 Actor 切换
        for item in items {
            process(item)  // 同步处理
        }
    }
    
    private func process(_ item: Item) {
        // 不含 await
    }
}
```

---

## 八、性能优化

### 8.1 避免过度 Actor 化

```swift
// ❌ 过度：每个小对象都是 Actor
actor SmallValue {
    var value: Int = 0
}

actor Container {
    var items: [SmallValue] = []  // 访问每个 item 都要 await
}

// ✅ 合理：整体隔离
actor Container {
    struct Item {  // 普通结构体
        var value: Int
    }
    
    private var items: [Item] = []  // 整体隔离
    
    func getItem(_ index: Int) -> Item? {
        items[index]  // 一次 await
    }
}
```

### 8.2 减少边界跨越

```swift
// ❌ 频繁跨越
@MainActor
class ViewModel {
    let service: MyActor
    
    func update() async {
        for i in 0..<100 {
            await service.process(i)  // 100 次 Actor 切换
        }
    }
}

// ✅ 批量操作
@MainActor
class ViewModel {
    let service: MyActor
    
    func update() async {
        await service.processBatch(0..<100)  // 1 次 Actor 切换
    }
}
```

---

## 九、调试工具

### 9.1 Thread Sanitizer (TSan)

在 Xcode 中启用 **Thread Sanitizer**：

1. Edit Scheme → Run → Diagnostics
2. 勾选 "Thread Sanitizer"
3. 运行应用

TSan 会检测：
- 数据竞争
- 锁顺序问题
- 线程泄漏

### 9.2 Actor 日志

```swift
actor DebugActor {
    private let name: String
    
    init(name: String) {
        self.name = name
        print("🎭 Actor[\(name)] initialized on thread \(Thread.current)")
    }
    
    func doSomething() async {
        print("🎭 Actor[\(name)] executing on thread \(Thread.current)")
        // ...
    }
}
```

### 9.3 性能分析

```swift
actor PerformanceMonitor {
    private var startTime: Date?
    
    func begin() {
        startTime = Date()
    }
    
    func end(operation: String) {
        guard let start = startTime else { return }
        let duration = Date().timeIntervalSince(start)
        print("⏱️ [\(operation)] took \(duration * 1000)ms")
        startTime = nil
    }
}

// 使用
await monitor.begin()
try await someOperation()
await monitor.end(operation: "someOperation")
```

---

## 十、测试并发代码

### 10.1 Actor 单元测试

```swift
class ActorTests: XCTestCase {
    func testActorIsolation() async throws {
        let counter = Counter()
        
        // 并发递增
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    await counter.increment()
                }
            }
        }
        
        // 验证结果
        let value = await counter.getValue()
        XCTAssertEqual(value, 1000)  // 无数据竞争
    }
}

actor Counter {
    private var value: Int = 0
    
    func increment() {
        value += 1
    }
    
    func getValue() -> Int {
        value
    }
}
```

### 10.2 竞争条件测试

```swift
class RaceConditionTests: XCTestCase {
    func testNoRaceCondition() async throws {
        let resource = SharedResource()
        
        // 模拟高并发
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try await resource.access(id: i)
                }
            }
            
            try await group.waitForAll()
        }
        
        // 验证状态一致性
        let isConsistent = await resource.checkConsistency()
        XCTAssertTrue(isConsistent)
    }
}
```

---

## 总结

### 关键设计点

1. **Actor 隔离**: 所有状态由 Actor 保护，编译器保证线程安全
2. **@MainActor**: UI 代码严格在主线程
3. **无锁音频**: 音频线程使用无锁数据结构
4. **结构化并发**: Task Group 管理任务生命周期
5. **AsyncStream**: 类型安全的事件流

### 并发模型特性

- ✅ 零数据竞争（编译器保证）
- ✅ Actor 自动串行化
- ✅ 无锁音频线程
- ✅ MainActor UI 隔离
- ✅ 结构化并发管理

### 与 Backend 对照

| Backend (Go) | iOS (Swift) |
|-------------|-------------|
| goroutine | Task |
| channel | AsyncStream |
| sync.Mutex | Actor (自动) |
| sync.WaitGroup | TaskGroup |
| select | AsyncStream merge |

下一步: [08_implementation_roadmap.md](08_implementation_roadmap.md) - 实施路线图
