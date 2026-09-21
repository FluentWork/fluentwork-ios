# 性能优化策略

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 9  
**状态**: 设计阶段

---

## 一、优化目标

| 指标 | 目标 | 当前基线 |
|------|------|----------|
| 首响延迟 P90 | ≤ 1.5s | TBD |
| 内存占用 | ≤ 150 MB | TBD |
| 电池消耗 | ≤ 5%/10min | TBD |
| 应用启动时间 | ≤ 2s | TBD |
| 即时反馈延迟 | ≤ 500ms | TBD |

---

## 二、首响延迟优化

### 2.1 延迟预算分解

```
用户说话结束
  ↓ ≤200ms    VAD 检测 + 音频缓冲
ASR 识别完成
  ↓ ≤800ms    LLM 处理 + 首 token
LLM 首 token
  ↓ ≤300ms    TTS 合成首音频块
TTS 首音频块
  ↓ ≤200ms    网络传输 + 播放启动
音频播放开始
= 1.5s (P90)
```

### 2.2 优化策略

**策略 1: 预连接**

```swift
actor PreconnectionManager {
    private let transport: WebSocketTransport
    
    func warmup() async {
        // 在用户点击"开始"前就建立 WebSocket 连接
        do {
            try await transport.connect()
            Logger.info("WebSocket pre-connected")
        } catch {
            Logger.warning("Pre-connection failed: \(error)")
        }
    }
}

// 在应用启动或进入房间页面时调用
Task {
    await preconnectionManager.warmup()
}
```

**策略 2: 流式处理优先**

```swift
// ASR 流式识别，不等待完整句子
func enableStreamingASR() {
    asrConfig.streamingMode = true
    asrConfig.interimResults = true
}

// LLM 流式生成
func enableStreamingLLM() {
    llmConfig.stream = true
}

// TTS 流式合成
func enableStreamingTTS() {
    ttsConfig.streamingMode = true
    ttsConfig.chunkSize = 1024  // 小块，快速返回
}
```

**策略 3: 本地 VAD 加速**

```swift
actor LocalVADDetector {
    private let model: MLModel
    
    func detectEndOfSpeech(audioBuffer: AVAudioPCMBuffer) -> Bool {
        // 使用 Core ML 本地 VAD 模型
        // 避免等待后端响应
        let features = extractFeatures(audioBuffer)
        let prediction = try? model.prediction(from: features)
        return prediction?.isSilence ?? false
    }
}
```

**策略 4: Prompt 缓存**

```swift
actor PromptCache {
    private var cache: [String: String] = [:]
    
    func getSystemPrompt(for scenario: ScenarioType) -> String {
        if let cached = cache[scenario.rawValue] {
            return cached
        }
        
        let prompt = buildSystemPrompt(scenario)
        cache[scenario.rawValue] = prompt
        return prompt
    }
}
```

---

## 三、内存优化

### 3.1 音频数据管理

```swift
actor AudioDataManager {
    private var audioChunks: [UUID: [Data]] = [:]
    private let maxChunksPerSession = 1000  // 约 10 分钟
    
    func addAudioChunk(_ data: Data, for sessionID: UUID) {
        var chunks = audioChunks[sessionID, default: []]
        chunks.append(data)
        
        // 超过限制，删除最早的
        if chunks.count > maxChunksPerSession {
            chunks.removeFirst()
        }
        
        audioChunks[sessionID] = chunks
    }
    
    func clearSession(_ sessionID: UUID) {
        audioChunks.removeValue(forKey: sessionID)
    }
    
    func getMemoryUsage() -> Int {
        audioChunks.values.flatMap { $0 }.reduce(0) { $0 + $1.count }
    }
}
```

### 3.2 转录数据压缩

```swift
struct CompactTurn: Codable {
    let s: Int       // speaker: 0=user, 1=ai
    let t: String    // transcript
    let ts: Double   // timestamp (epoch)
}

actor TranscriptCompressor {
    func compress(_ turns: [Turn]) -> Data {
        let compact = turns.map { turn in
            CompactTurn(
                s: turn.speaker == .user ? 0 : 1,
                t: turn.transcript,
                ts: turn.timestamp.timeIntervalSince1970
            )
        }
        
        return try! JSONEncoder().encode(compact)
    }
}
```

### 3.3 内存监控

```swift
actor MemoryMonitor {
    private var observations: [MemoryObservation] = []
    
    func startMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task {
                await self?.recordMemoryUsage()
            }
        }
    }
    
    private func recordMemoryUsage() {
        let usage = getMemoryUsage()
        observations.append(MemoryObservation(usage: usage, timestamp: Date()))
        
        if usage > 150 * 1024 * 1024 {  // 150 MB
            Logger.warning("Memory usage high: \(usage / 1024 / 1024) MB")
            triggerMemoryWarning()
        }
    }
    
    private func getMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    
    private func triggerMemoryWarning() {
        // 清理缓存
    }
}

struct MemoryObservation {
    let usage: Int
    let timestamp: Date
}
```

---

## 四、电池优化

### 4.1 降低采样率

```swift
actor AudioOptimizer {
    func optimizeForBattery() {
        // 降低采样率（语音识别仍然准确）
        audioConfig.sampleRate = 16000  // 从 44100 降至 16000
        audioConfig.bitDepth = 16       // 保持 16-bit
        audioConfig.channels = 1        // 单声道
    }
}
```

### 4.2 智能后台策略

```swift
actor BackgroundOptimizer {
    func optimizeForBackground() {
        // 暂停非关键任务
        pauseAnalytics()
        pauseSyncOperations()
        
        // 降低更新频率
        reduceUIUpdateFrequency()
    }
    
    func restoreFromBackground() {
        resumeAnalytics()
        resumeSyncOperations()
        restoreUIUpdateFrequency()
    }
}
```

### 4.3 网络请求优化

```swift
actor NetworkOptimizer {
    func optimizeRequests() {
        // 批量上传
        uploadQueue.batchSize = 10
        uploadQueue.uploadInterval = 30.0  // 30 秒一次
        
        // 压缩数据
        apiClient.compressionEnabled = true
        
        // 使用 HTTP/2
        apiClient.useHTTP2 = true
    }
}
```

---

## 五、启动时间优化

### 5.1 延迟加载

```swift
@main
struct FluentWorkApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        // 只初始化必要组件
        initializeCoreServices()
        
        // 延迟初始化非关键组件
        Task {
            await initializeSecondaryServices()
        }
    }
    
    private func initializeCoreServices() {
        // 必须：依赖注入容器
        _ = DependencyContainer.shared
    }
    
    private func initializeSecondaryServices() async {
        // 可延迟：分析服务
        await AnalyticsService.shared.initialize()
        
        // 可延迟：预连接
        await PreconnectionManager.shared.warmup()
    }
}
```

### 5.2 资源预加载

```swift
actor ResourcePreloader {
    func preloadCriticalResources() async {
        // 预加载常用素材
        await preloadPresetScenarios()
        
        // 预加载 ML 模型
        await preloadMLModels()
    }
    
    private func preloadPresetScenarios() async {
        // 从 Bundle 加载
    }
    
    private func preloadMLModels() async {
        // 加载 VAD、Embedding 模型
    }
}
```

---

## 六、并发优化

### 6.1 Task 优先级

```swift
// 高优先级：用户交互
Task(priority: .userInitiated) {
    await processUserInput()
}

// 中优先级：即时反馈检测
Task(priority: .userInitiated) {
    await detectPhraseMatches()
}

// 低优先级：数据同步
Task(priority: .background) {
    await syncToBackend()
}
```

### 6.2 并发限制

```swift
actor ConcurrencyLimiter {
    private var activeCount = 0
    private let maxConcurrent: Int
    
    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }
    
    func withLimit<T>(_ operation: @escaping () async throws -> T) async rethrows -> T {
        while activeCount >= maxConcurrent {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        
        activeCount += 1
        defer { activeCount -= 1 }
        
        return try await operation()
    }
}

// 使用
let limiter = ConcurrencyLimiter(maxConcurrent: 5)
await limiter.withLimit {
    await heavyOperation()
}
```

---

## 七、网络优化

### 7.1 请求合并

```swift
actor RequestBatcher {
    private var pendingRequests: [PhraseBlock] = []
    private var batchTimer: Task<Void, Never>?
    
    func addRequest(_ phraseBlock: PhraseBlock) async {
        pendingRequests.append(phraseBlock)
        
        if batchTimer == nil {
            batchTimer = Task {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                await flush()
            }
        }
    }
    
    private func flush() async {
        guard !pendingRequests.isEmpty else { return }
        
        let batch = pendingRequests
        pendingRequests.removeAll()
        batchTimer = nil
        
        // 批量上传
        try? await apiService.batchSync(batch)
    }
}
```

### 7.2 缓存策略

```swift
actor HTTPCache {
    private var cache: [URL: CachedResponse] = [:]
    
    func getCachedResponse(for url: URL) -> CachedResponse? {
        guard let cached = cache[url] else { return nil }
        
        // 检查是否过期
        if Date().timeIntervalSince(cached.timestamp) > cached.maxAge {
            cache.removeValue(forKey: url)
            return nil
        }
        
        return cached
    }
    
    func cacheResponse(_ response: HTTPURLResponse, data: Data, for url: URL) {
        let maxAge = parseCacheControl(response)
        cache[url] = CachedResponse(
            data: data,
            timestamp: Date(),
            maxAge: maxAge
        )
    }
    
    private func parseCacheControl(_ response: HTTPURLResponse) -> TimeInterval {
        guard let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") else {
            return 300  // 默认 5 分钟
        }
        
        // 解析 max-age
        let components = cacheControl.components(separatedBy: ",")
        for component in components {
            if component.trimmingCharacters(in: .whitespaces).hasPrefix("max-age=") {
                let value = component.replacingOccurrences(of: "max-age=", with: "")
                return TimeInterval(value.trimmingCharacters(in: .whitespaces)) ?? 300
            }
        }
        
        return 300
    }
}

struct CachedResponse {
    let data: Data
    let timestamp: Date
    let maxAge: TimeInterval
}
```

---

## 八、监控仪表盘

### 8.1 性能指标采集

```swift
struct PerformanceMetrics: Codable {
    let sessionID: String
    let firstResponseLatency: TimeInterval
    let avgResponseLatency: TimeInterval
    let memoryUsage: Int
    let batteryDrain: Double
    let networkBytesIn: Int
    let networkBytesOut: Int
    let cpuUsage: Double
    let timestamp: Date
}

actor PerformanceCollector {
    private var metrics: [PerformanceMetrics] = []
    
    func recordMetrics(_ metrics: PerformanceMetrics) {
        self.metrics.append(metrics)
        
        // 每 100 个指标上报一次
        if self.metrics.count >= 100 {
            uploadMetrics()
        }
    }
    
    private func uploadMetrics() {
        Task {
            try? await apiService.uploadPerformanceMetrics(metrics)
            metrics.removeAll()
        }
    }
}
```

---

## 九、降级策略

### 9.1 性能降级

```swift
actor PerformanceDegradationManager {
    private var isPerformanceDegraded = false
    
    func checkAndDegrade() async {
        let memoryUsage = await memoryMonitor.getCurrentUsage()
        let batteryLevel = UIDevice.current.batteryLevel
        
        if memoryUsage > 150 * 1024 * 1024 || batteryLevel < 0.2 {
            await enableDegradedMode()
        } else if isPerformanceDegraded && memoryUsage < 100 * 1024 * 1024 && batteryLevel > 0.3 {
            await disableDegradedMode()
        }
    }
    
    private func enableDegradedMode() async {
        isPerformanceDegraded = true
        
        // 降级措施
        await instantFeedbackDetector.disable()
        await audioOptimizer.reduceSampleRate()
        await networkOptimizer.enableCompression()
        
        Logger.warning("Performance degraded mode enabled")
    }
    
    private func disableDegradedMode() async {
        isPerformanceDegraded = false
        
        await instantFeedbackDetector.enable()
        await audioOptimizer.restoreSampleRate()
        
        Logger.info("Performance degraded mode disabled")
    }
}
```

---

## 十、测试策略

```swift
@Test
func testFirstResponseLatency() async throws {
    let service = PracticeRoomService(/* ... */)
    let startTime = Date()
    
    try await service.startSession(/* ... */)
    
    // 模拟用户说话
    try await service.processUserUtterance("Hello")
    
    // 等待 AI 响应
    var firstResponseTime: TimeInterval?
    for await event in await service.events {
        if case .aiAudioChunk = event {
            firstResponseTime = Date().timeIntervalSince(startTime)
            break
        }
    }
    
    #expect(firstResponseTime != nil)
    #expect(firstResponseTime! <= 1.5, "First response latency \(firstResponseTime!)s exceeds 1.5s")
}

@Test
func testMemoryUsage() async {
    let monitor = MemoryMonitor()
    await monitor.startMonitoring()
    
    // 运行 10 分钟会话模拟
    for _ in 0..<100 {
        try? await Task.sleep(nanoseconds: 6_000_000_000)  // 6s
    }
    
    let peakUsage = await monitor.getPeakUsage()
    #expect(peakUsage <= 150 * 1024 * 1024, "Peak memory usage \(peakUsage / 1024 / 1024)MB exceeds 150MB")
}
```

---

**最后更新**: 2026-09-21  
**下一文档**: [10_testing_strategy.md](10_testing_strategy.md)
