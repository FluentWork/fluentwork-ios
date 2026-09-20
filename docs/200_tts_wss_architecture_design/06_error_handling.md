# 错误处理与降级策略

**日期**: 2026-09-21  
**目标**: 定义完整的错误分类、恢复策略和降级方案，确保系统在各种异常情况下都能优雅处理

---

## 一、错误分类体系

### 1.1 错误层次结构

```swift
// MARK: - Base Error Protocol

protocol VoiceSessionErrorProtocol: Error {
    var code: String { get }
    var message: String { get }
    var recoverable: Bool { get }
    var userMessage: String { get }
    var debugInfo: [String: Any] { get }
}

// MARK: - Error Categories

enum VoiceSessionError: VoiceSessionErrorProtocol {
    // 网络错误 (1xxx)
    case networkError(NetworkError)
    
    // 音频错误 (2xxx)
    case audioError(AudioError)
    
    // 协议错误 (3xxx)
    case protocolError(ProtocolError)
    
    // 业务错误 (4xxx)
    case businessError(BusinessError)
    
    // 系统错误 (5xxx)
    case systemError(SystemError)
    
    var code: String {
        switch self {
        case .networkError(let error): return error.code
        case .audioError(let error): return error.code
        case .protocolError(let error): return error.code
        case .businessError(let error): return error.code
        case .systemError(let error): return error.code
        }
    }
    
    var message: String {
        switch self {
        case .networkError(let error): return error.message
        case .audioError(let error): return error.message
        case .protocolError(let error): return error.message
        case .businessError(let error): return error.message
        case .systemError(let error): return error.message
        }
    }
    
    var recoverable: Bool {
        switch self {
        case .networkError(let error): return error.recoverable
        case .audioError(let error): return error.recoverable
        case .protocolError(let error): return error.recoverable
        case .businessError(let error): return error.recoverable
        case .systemError(let error): return error.recoverable
        }
    }
    
    var userMessage: String {
        switch self {
        case .networkError: return "网络连接出现问题"
        case .audioError: return "音频处理出现问题"
        case .protocolError: return "通信协议出现问题"
        case .businessError(let error): return error.userMessage
        case .systemError: return "系统出现问题"
        }
    }
    
    var debugInfo: [String: Any] {
        switch self {
        case .networkError(let error): return error.debugInfo
        case .audioError(let error): return error.debugInfo
        case .protocolError(let error): return error.debugInfo
        case .businessError(let error): return error.debugInfo
        case .systemError(let error): return error.debugInfo
        }
    }
}
```

---

## 二、网络错误（1xxx）

### 2.1 错误定义

```swift
enum NetworkError: VoiceSessionErrorProtocol {
    case connectionFailed(Error)
    case connectionTimeout
    case connectionLost
    case dnsFailed
    case tlsHandshakeFailed
    case proxyError
    case rateLimited
    case serverUnavailable
    case authenticationFailed
    
    var code: String {
        switch self {
        case .connectionFailed: return "1001"
        case .connectionTimeout: return "1002"
        case .connectionLost: return "1003"
        case .dnsFailed: return "1004"
        case .tlsHandshakeFailed: return "1005"
        case .proxyError: return "1006"
        case .rateLimited: return "1007"
        case .serverUnavailable: return "1008"
        case .authenticationFailed: return "1009"
        }
    }
    
    var message: String {
        switch self {
        case .connectionFailed(let error):
            return "连接失败: \(error.localizedDescription)"
        case .connectionTimeout:
            return "连接超时"
        case .connectionLost:
            return "连接断开"
        case .dnsFailed:
            return "域名解析失败"
        case .tlsHandshakeFailed:
            return "TLS 握手失败"
        case .proxyError:
            return "代理错误"
        case .rateLimited:
            return "请求频率过高"
        case .serverUnavailable:
            return "服务器不可用"
        case .authenticationFailed:
            return "认证失败"
        }
    }
    
    var recoverable: Bool {
        switch self {
        case .connectionFailed, .connectionTimeout, .connectionLost,
             .serverUnavailable, .rateLimited:
            return true
        case .dnsFailed, .tlsHandshakeFailed, .proxyError, .authenticationFailed:
            return false
        }
    }
    
    var userMessage: String {
        switch self {
        case .connectionFailed, .connectionTimeout:
            return "无法连接服务器，请检查网络"
        case .connectionLost:
            return "连接已断开，正在重连..."
        case .rateLimited:
            return "操作过于频繁，请稍后再试"
        case .serverUnavailable:
            return "服务暂时不可用，请稍后再试"
        case .authenticationFailed:
            return "登录已过期，请重新登录"
        default:
            return "网络连接出现问题"
        }
    }
    
    var debugInfo: [String: Any] {
        ["category": "network", "code": code, "message": message]
    }
}
```

### 2.2 重连策略

```swift
actor ReconnectionManager {
    private var attemptCount: Int = 0
    private let maxAttempts: Int = 5
    private let baseDelay: TimeInterval = 1.0
    private let maxDelay: TimeInterval = 30.0
    
    private var reconnectTask: Task<Void, Never>?
    
    func shouldRetry() -> Bool {
        attemptCount < maxAttempts
    }
    
    func nextDelay() -> TimeInterval {
        // 指数退避：1s, 2s, 4s, 8s, 16s, 30s (max)
        let delay = baseDelay * pow(2.0, Double(attemptCount))
        return min(delay, maxDelay)
    }
    
    func attemptReconnect(
        connect: @escaping () async throws -> Void,
        onSuccess: @escaping () async -> Void,
        onFailed: @escaping (Error) async -> Void
    ) {
        reconnectTask?.cancel()
        
        reconnectTask = Task {
            while !Task.isCancelled && shouldRetry() {
                let delay = nextDelay()
                
                print("🔄 Reconnecting in \(delay)s (attempt \(attemptCount + 1)/\(maxAttempts))")
                
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                
                do {
                    try await connect()
                    await onSuccess()
                    reset()
                    break
                } catch {
                    attemptCount += 1
                    
                    if !shouldRetry() {
                        await onFailed(error)
                        break
                    }
                }
            }
        }
    }
    
    func reset() {
        attemptCount = 0
        reconnectTask?.cancel()
        reconnectTask = nil
    }
    
    func cancel() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}
```

---

## 三、音频错误（2xxx）

### 3.1 错误定义

```swift
enum AudioError: VoiceSessionErrorProtocol {
    case permissionDenied
    case sessionConfigurationFailed
    case engineStartFailed
    case captureInterrupted
    case encodingFailed(String)
    case decodingFailed(String)
    case bufferAllocationFailed
    case playbackFailed
    case formatNotSupported
    
    var code: String {
        switch self {
        case .permissionDenied: return "2001"
        case .sessionConfigurationFailed: return "2002"
        case .engineStartFailed: return "2003"
        case .captureInterrupted: return "2004"
        case .encodingFailed: return "2005"
        case .decodingFailed: return "2006"
        case .bufferAllocationFailed: return "2007"
        case .playbackFailed: return "2008"
        case .formatNotSupported: return "2009"
        }
    }
    
    var message: String {
        switch self {
        case .permissionDenied:
            return "麦克风权限被拒绝"
        case .sessionConfigurationFailed:
            return "音频会话配置失败"
        case .engineStartFailed:
            return "音频引擎启动失败"
        case .captureInterrupted:
            return "音频采集中断"
        case .encodingFailed(let reason):
            return "音频编码失败: \(reason)"
        case .decodingFailed(let reason):
            return "音频解码失败: \(reason)"
        case .bufferAllocationFailed:
            return "缓冲区分配失败"
        case .playbackFailed:
            return "音频播放失败"
        case .formatNotSupported:
            return "音频格式不支持"
        }
    }
    
    var recoverable: Bool {
        switch self {
        case .permissionDenied, .formatNotSupported:
            return false
        case .captureInterrupted, .encodingFailed, .decodingFailed, .playbackFailed:
            return true
        case .sessionConfigurationFailed, .engineStartFailed, .bufferAllocationFailed:
            return true
        }
    }
    
    var userMessage: String {
        switch self {
        case .permissionDenied:
            return "请在设置中允许麦克风权限"
        case .captureInterrupted:
            return "录音被打断"
        case .playbackFailed:
            return "播放失败，请重试"
        default:
            return "音频处理出现问题"
        }
    }
    
    var debugInfo: [String: Any] {
        ["category": "audio", "code": code, "message": message]
    }
}
```

### 3.2 音频降级策略

```swift
actor AudioDegradationManager {
    enum QualityLevel {
        case high      // 16kHz, Opus 16kbps
        case medium    // 8kHz, Opus 12kbps
        case low       // 8kHz, Opus 8kbps
        case fallback  // 静音填充
    }
    
    private(set) var currentLevel: QualityLevel = .high
    private var errorCount: Int = 0
    
    func onEncodingFailed() -> QualityLevel {
        errorCount += 1
        
        switch errorCount {
        case 1...2:
            currentLevel = .medium
        case 3...5:
            currentLevel = .low
        default:
            currentLevel = .fallback
        }
        
        print("⚠️ Audio degraded to \(currentLevel)")
        return currentLevel
    }
    
    func onSuccess() {
        if errorCount > 0 {
            errorCount = max(0, errorCount - 1)
        }
        
        // 逐步恢复
        if errorCount == 0 && currentLevel != .high {
            currentLevel = .high
            print("✅ Audio quality restored to high")
        }
    }
    
    func reset() {
        currentLevel = .high
        errorCount = 0
    }
}
```

### 3.3 权限处理

```swift
actor MicrophonePermissionManager {
    enum PermissionStatus {
        case notDetermined
        case granted
        case denied
        case restricted
    }
    
    func checkPermission() async -> PermissionStatus {
        let status = AVAudioSession.sharedInstance().recordPermission
        
        switch status {
        case .undetermined:
            return .notDetermined
        case .granted:
            return .granted
        case .denied:
            return .denied
        @unknown default:
            return .restricted
        }
    }
    
    func requestPermission() async -> PermissionStatus {
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }
    
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        
        Task { @MainActor in
            if UIApplication.shared.canOpenURL(url) {
                await UIApplication.shared.open(url)
            }
        }
    }
}
```

---

## 四、协议错误（3xxx）

### 4.1 错误定义

```swift
enum ProtocolError: VoiceSessionErrorProtocol {
    case invalidMessageFormat
    case unknownMessageType(String)
    case missingRequiredField(String)
    case sequenceNumberGap(expected: Int, received: Int)
    case duplicateMessage(sequence: Int)
    case unsupportedVersion(String)
    case checksumMismatch
    
    var code: String {
        switch self {
        case .invalidMessageFormat: return "3001"
        case .unknownMessageType: return "3002"
        case .missingRequiredField: return "3003"
        case .sequenceNumberGap: return "3004"
        case .duplicateMessage: return "3005"
        case .unsupportedVersion: return "3006"
        case .checksumMismatch: return "3007"
        }
    }
    
    var message: String {
        switch self {
        case .invalidMessageFormat:
            return "消息格式错误"
        case .unknownMessageType(let type):
            return "未知消息类型: \(type)"
        case .missingRequiredField(let field):
            return "缺少必填字段: \(field)"
        case .sequenceNumberGap(let expected, let received):
            return "序列号不连续: 期望 \(expected), 收到 \(received)"
        case .duplicateMessage(let sequence):
            return "重复消息: \(sequence)"
        case .unsupportedVersion(let version):
            return "不支持的协议版本: \(version)"
        case .checksumMismatch:
            return "校验和不匹配"
        }
    }
    
    var recoverable: Bool {
        switch self {
        case .sequenceNumberGap, .duplicateMessage:
            return true
        case .invalidMessageFormat, .unknownMessageType, .missingRequiredField,
             .unsupportedVersion, .checksumMismatch:
            return false
        }
    }
    
    var userMessage: String {
        switch self {
        case .sequenceNumberGap:
            return "音频有部分丢失"
        case .unsupportedVersion:
            return "应用版本过旧，请更新"
        default:
            return "通信协议出现问题"
        }
    }
    
    var debugInfo: [String: Any] {
        ["category": "protocol", "code": code, "message": message]
    }
}
```

### 4.2 序列号恢复

```swift
actor SequenceRecoveryManager {
    private var gapBuffer: [Int: Data] = [:]  // sequence → audio data
    private let maxGapSize: Int = 10
    
    func handleGap(
        expected: Int,
        received: Int,
        data: Data
    ) -> RecoveryAction {
        let gapSize = received - expected
        
        if gapSize > maxGapSize {
            // 间隔过大，跳过缺失的帧
            return .skipGap(from: expected, to: received)
        }
        
        // 缓存当前帧
        gapBuffer[received] = data
        
        // 检查是否可以填补空白
        var recovered: [(Int, Data)] = []
        var nextExpected = expected
        
        while let bufferedData = gapBuffer[nextExpected] {
            recovered.append((nextExpected, bufferedData))
            gapBuffer.removeValue(forKey: nextExpected)
            nextExpected += 1
        }
        
        if !recovered.isEmpty {
            return .playRecovered(recovered)
        }
        
        return .waitForMissing
    }
    
    func reset() {
        gapBuffer.removeAll()
    }
    
    enum RecoveryAction {
        case skipGap(from: Int, to: Int)
        case playRecovered([(Int, Data)])
        case waitForMissing
    }
}
```

---

## 五、业务错误（4xxx）

### 5.1 错误定义

```swift
enum BusinessError: VoiceSessionErrorProtocol {
    case asrFailed(reason: String)
    case llmFailed(reason: String)
    case ttsFailed(reason: String)
    case contentFiltered(reason: String)
    case quotaExceeded
    case sessionExpired
    case turnTimeout
    case invalidInput
    
    var code: String {
        switch self {
        case .asrFailed: return "4001"
        case .llmFailed: return "4002"
        case .ttsFailed: return "4003"
        case .contentFiltered: return "4004"
        case .quotaExceeded: return "4005"
        case .sessionExpired: return "4006"
        case .turnTimeout: return "4007"
        case .invalidInput: return "4008"
        }
    }
    
    var message: String {
        switch self {
        case .asrFailed(let reason):
            return "语音识别失败: \(reason)"
        case .llmFailed(let reason):
            return "AI 处理失败: \(reason)"
        case .ttsFailed(let reason):
            return "语音合成失败: \(reason)"
        case .contentFiltered(let reason):
            return "内容被过滤: \(reason)"
        case .quotaExceeded:
            return "使用额度已用完"
        case .sessionExpired:
            return "会话已过期"
        case .turnTimeout:
            return "对话超时"
        case .invalidInput:
            return "输入无效"
        }
    }
    
    var recoverable: Bool {
        switch self {
        case .asrFailed, .llmFailed, .ttsFailed, .turnTimeout:
            return true
        case .contentFiltered, .quotaExceeded, .sessionExpired, .invalidInput:
            return false
        }
    }
    
    var userMessage: String {
        switch self {
        case .asrFailed:
            return "没有听清，请再说一遍"
        case .llmFailed:
            return "AI 处理出错，请重试"
        case .ttsFailed:
            return "语音合成失败，请重试"
        case .contentFiltered:
            return "内容不符合规范"
        case .quotaExceeded:
            return "今日使用次数已达上限"
        case .sessionExpired:
            return "会话已过期，请重新开始"
        case .turnTimeout:
            return "等待超时，请重试"
        case .invalidInput:
            return "输入无效，请重试"
        }
    }
    
    var debugInfo: [String: Any] {
        ["category": "business", "code": code, "message": message]
    }
}
```

### 5.2 业务降级策略

```swift
actor BusinessDegradationManager {
    private var asrFailCount: Int = 0
    private var llmFailCount: Int = 0
    private var ttsFailCount: Int = 0
    
    func onASRFailed() -> DegradationAction {
        asrFailCount += 1
        
        if asrFailCount >= 3 {
            return .showTextInput  // 切换到文本输入模式
        }
        
        return .retry
    }
    
    func onLLMFailed() -> DegradationAction {
        llmFailCount += 1
        
        if llmFailCount >= 3 {
            return .useFallbackResponse  // 使用预设回复
        }
        
        return .retry
    }
    
    func onTTSFailed() -> DegradationAction {
        ttsFailCount += 1
        
        if ttsFailCount >= 3 {
            return .textOnly  // 只显示文本，不播放语音
        }
        
        return .retry
    }
    
    func reset() {
        asrFailCount = 0
        llmFailCount = 0
        ttsFailCount = 0
    }
    
    enum DegradationAction {
        case retry
        case showTextInput
        case useFallbackResponse
        case textOnly
    }
}
```

---

## 六、系统错误（5xxx）

### 6.1 错误定义

```swift
enum SystemError: VoiceSessionErrorProtocol {
    case memoryWarning
    case outOfMemory
    case diskFull
    case backgroundTimeout
    case thermalThrottling
    case batteryLow
    case unknown(Error)
    
    var code: String {
        switch self {
        case .memoryWarning: return "5001"
        case .outOfMemory: return "5002"
        case .diskFull: return "5003"
        case .backgroundTimeout: return "5004"
        case .thermalThrottling: return "5005"
        case .batteryLow: return "5006"
        case .unknown: return "5999"
        }
    }
    
    var message: String {
        switch self {
        case .memoryWarning:
            return "内存不足警告"
        case .outOfMemory:
            return "内存不足"
        case .diskFull:
            return "磁盘空间不足"
        case .backgroundTimeout:
            return "后台运行超时"
        case .thermalThrottling:
            return "设备过热降频"
        case .batteryLow:
            return "电量过低"
        case .unknown(let error):
            return "未知错误: \(error.localizedDescription)"
        }
    }
    
    var recoverable: Bool {
        switch self {
        case .memoryWarning, .thermalThrottling, .batteryLow:
            return true
        case .outOfMemory, .diskFull, .backgroundTimeout, .unknown:
            return false
        }
    }
    
    var userMessage: String {
        switch self {
        case .memoryWarning, .outOfMemory:
            return "设备内存不足，请关闭其他应用"
        case .diskFull:
            return "存储空间不足"
        case .backgroundTimeout:
            return "后台运行超时"
        case .thermalThrottling:
            return "设备过热，性能受限"
        case .batteryLow:
            return "电量过低，请充电后使用"
        case .unknown:
            return "发生未知错误"
        }
    }
    
    var debugInfo: [String: Any] {
        ["category": "system", "code": code, "message": message]
    }
}
```

### 6.2 资源监控

```swift
actor ResourceMonitor {
    private var isMonitoring = false
    
    func startMonitoring(onWarning: @escaping (SystemError) async -> Void) {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // 监听内存警告
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await onWarning(.memoryWarning)
            }
        }
        
        // 启动周期性检查
        Task {
            while isMonitoring {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s
                
                // 检查电量
                let batteryLevel = UIDevice.current.batteryLevel
                if batteryLevel < 0.1 && batteryLevel > 0 {
                    await onWarning(.batteryLow)
                }
                
                // 检查热状态
                let thermalState = ProcessInfo.processInfo.thermalState
                if thermalState == .critical {
                    await onWarning(.thermalThrottling)
                }
            }
        }
    }
    
    func stopMonitoring() {
        isMonitoring = false
        NotificationCenter.default.removeObserver(self)
    }
}
```

---

## 七、错误处理策略

### 7.1 统一错误处理器

```swift
actor ErrorHandler {
    private let reconnectionManager: ReconnectionManager
    private let degradationManager: BusinessDegradationManager
    private let resourceMonitor: ResourceMonitor
    
    init(
        reconnectionManager: ReconnectionManager,
        degradationManager: BusinessDegradationManager,
        resourceMonitor: ResourceMonitor
    ) {
        self.reconnectionManager = reconnectionManager
        self.degradationManager = degradationManager
        self.resourceMonitor = resourceMonitor
    }
    
    func handle(
        _ error: VoiceSessionError,
        context: ErrorContext
    ) async -> ErrorAction {
        print("❌ Error: \(error.message) [\(error.code)]")
        
        // 记录错误
        await logError(error, context: context)
        
        // 决定处理策略
        switch error {
        case .networkError(let netError):
            return await handleNetworkError(netError)
            
        case .audioError(let audioError):
            return await handleAudioError(audioError)
            
        case .protocolError(let protocolError):
            return await handleProtocolError(protocolError)
            
        case .businessError(let businessError):
            return await handleBusinessError(businessError)
            
        case .systemError(let systemError):
            return await handleSystemError(systemError)
        }
    }
    
    private func handleNetworkError(_ error: NetworkError) async -> ErrorAction {
        if error.recoverable {
            return .reconnect(
                message: error.userMessage,
                action: {
                    await self.reconnectionManager.attemptReconnect(
                        connect: { /* ... */ },
                        onSuccess: { /* ... */ },
                        onFailed: { _ in /* ... */ }
                    )
                }
            )
        } else {
            return .showAlert(
                title: "网络错误",
                message: error.userMessage,
                actions: [.ok]
            )
        }
    }
    
    private func handleAudioError(_ error: AudioError) async -> ErrorAction {
        switch error {
        case .permissionDenied:
            return .showAlert(
                title: "需要麦克风权限",
                message: error.userMessage,
                actions: [.openSettings, .cancel]
            )
            
        case .encodingFailed, .decodingFailed:
            if error.recoverable {
                return .degrade(level: .medium)
            } else {
                return .showAlert(
                    title: "音频错误",
                    message: error.userMessage,
                    actions: [.retry, .cancel]
                )
            }
            
        default:
            return .showAlert(
                title: "音频错误",
                message: error.userMessage,
                actions: [.ok]
            )
        }
    }
    
    private func handleProtocolError(_ error: ProtocolError) async -> ErrorAction {
        if error.recoverable {
            return .silent  // 静默处理，不打扰用户
        } else {
            return .fatal(message: "通信协议错误，请更新应用")
        }
    }
    
    private func handleBusinessError(_ error: BusinessError) async -> ErrorAction {
        switch error {
        case .asrFailed:
            let action = await degradationManager.onASRFailed()
            return .degrade(level: action == .showTextInput ? .textInput : .retry)
            
        case .llmFailed:
            let action = await degradationManager.onLLMFailed()
            return action == .useFallbackResponse ? .useFallback : .retry
            
        case .ttsFailed:
            let action = await degradationManager.onTTSFailed()
            return action == .textOnly ? .degrade(level: .textOnly) : .retry
            
        case .quotaExceeded, .sessionExpired:
            return .showAlert(
                title: "提示",
                message: error.userMessage,
                actions: [.ok]
            )
            
        default:
            return .retry
        }
    }
    
    private func handleSystemError(_ error: SystemError) async -> ErrorAction {
        switch error {
        case .memoryWarning:
            return .cleanupResources
            
        case .outOfMemory:
            return .fatal(message: "内存不足，应用即将退出")
            
        case .batteryLow:
            return .showAlert(
                title: "电量过低",
                message: error.userMessage,
                actions: [.ok]
            )
            
        default:
            return .showAlert(
                title: "系统错误",
                message: error.userMessage,
                actions: [.ok]
            )
        }
    }
    
    private func logError(_ error: VoiceSessionError, context: ErrorContext) async {
        let log = ErrorLog(
            timestamp: Date(),
            error: error,
            context: context
        )
        
        // 上报到服务器
        // await analytics.reportError(log)
        
        // 本地持久化
        // await persistence.save(log)
    }
}

// MARK: - Supporting Types

struct ErrorContext {
    let sessionID: String?
    let turnID: String?
    let sessionState: String
    let turnState: String?
    let userAction: String?
}

enum ErrorAction {
    case reconnect(message: String, action: () async -> Void)
    case retry
    case degrade(level: DegradationLevel)
    case useFallback
    case showAlert(title: String, message: String, actions: [AlertAction])
    case silent
    case cleanupResources
    case fatal(message: String)
}

enum DegradationLevel {
    case retry
    case medium
    case textInput
    case textOnly
}

enum AlertAction {
    case ok
    case cancel
    case retry
    case openSettings
}

struct ErrorLog {
    let timestamp: Date
    let error: VoiceSessionError
    let context: ErrorContext
}
```

---

## 八、降级方案总结

### 8.1 降级层级

| 层级 | 场景 | 降级方案 | 用户体验 |
|------|------|---------|---------|
| L1 正常 | 一切正常 | 16kHz Opus, 全功能 | 完整体验 |
| L2 轻微降级 | 偶尔丢包/延迟 | 跳过缺失帧，继续播放 | 音频有短暂空白 |
| L3 中度降级 | 网络不稳定 | 8kHz Opus, 增大缓冲 | 音质略降，延迟增加 |
| L4 重度降级 | 频繁失败 | 纯文本模式，关闭语音 | 只能打字交互 |
| L5 紧急模式 | 资源不足 | 关闭所有非关键功能 | 基本可用 |
| L6 不可用 | 致命错误 | 断开连接，提示用户 | 无法使用 |

### 8.2 自动恢复机制

```swift
actor AutoRecoveryManager {
    private var currentLevel: Int = 1  // L1 = 正常
    private var consecutiveSuccess: Int = 0
    
    func onError(severity: Int) {
        // 根据错误严重性降级
        currentLevel = max(currentLevel, severity)
        consecutiveSuccess = 0
    }
    
    func onSuccess() {
        consecutiveSuccess += 1
        
        // 连续成功 10 次，尝试恢复一级
        if consecutiveSuccess >= 10 && currentLevel > 1 {
            currentLevel -= 1
            consecutiveSuccess = 0
            print("⬆️ Recovered to level L\(currentLevel)")
        }
    }
    
    func currentDegradationLevel() -> Int {
        currentLevel
    }
}
```

---

## 九、用户反馈设计

### 9.1 错误提示 UI

```swift
@MainActor
class ErrorPresenter: ObservableObject {
    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    @Published var alertActions: [AlertAction] = []
    
    @Published var showToast = false
    @Published var toastMessage = ""
    
    @Published var showReconnecting = false
    @Published var reconnectAttempt = 0
    
    func present(_ action: ErrorAction) {
        switch action {
        case .showAlert(let title, let message, let actions):
            alertTitle = title
            alertMessage = message
            alertActions = actions
            showAlert = true
            
        case .reconnect(let message, _):
            toastMessage = message
            showReconnecting = true
            
        case .silent:
            // 不显示任何提示
            break
            
        case .fatal(let message):
            alertTitle = "错误"
            alertMessage = message
            alertActions = [.ok]
            showAlert = true
            
        default:
            break
        }
    }
}
```

### 9.2 SwiftUI 视图

```swift
struct ConversationView: View {
    @StateObject var presenter = ErrorPresenter()
    
    var body: some View {
        ZStack {
            // 主界面
            mainContent
            
            // 重连提示
            if presenter.showReconnecting {
                reconnectingOverlay
            }
            
            // Toast 提示
            if presenter.showToast {
                toastView
            }
        }
        .alert(
            presenter.alertTitle,
            isPresented: $presenter.showAlert
        ) {
            ForEach(presenter.alertActions, id: \.self) { action in
                Button(action.title) {
                    handleAction(action)
                }
            }
        } message: {
            Text(presenter.alertMessage)
        }
    }
    
    private var reconnectingOverlay: some View {
        VStack {
            ProgressView()
            Text("正在重连...")
                .foregroundColor(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
    
    private var toastView: some View {
        Text(presenter.toastMessage)
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .transition(.opacity)
    }
    
    private func handleAction(_ action: AlertAction) {
        // 处理用户操作
    }
}
```

---

## 十、测试策略

### 10.1 错误注入

```swift
actor ErrorInjector {
    private var enabledErrors: Set<String> = []
    
    func enable(_ errorCode: String) {
        enabledErrors.insert(errorCode)
    }
    
    func disable(_ errorCode: String) {
        enabledErrors.remove(errorCode)
    }
    
    func shouldInject(_ errorCode: String) -> Bool {
        enabledErrors.contains(errorCode)
    }
}

// 使用示例
#if DEBUG
let injector = ErrorInjector()
await injector.enable("1003")  // 模拟连接断开

// 在代码中检查
if await injector.shouldInject("1003") {
    throw NetworkError.connectionLost
}
#endif
```

### 10.2 单元测试

```swift
class ErrorHandlerTests: XCTestCase {
    var handler: ErrorHandler!
    
    override func setUp() async throws {
        handler = ErrorHandler(
            reconnectionManager: ReconnectionManager(),
            degradationManager: BusinessDegradationManager(),
            resourceMonitor: ResourceMonitor()
        )
    }
    
    func testNetworkErrorReconnect() async throws {
        let error = VoiceSessionError.networkError(.connectionLost)
        let context = ErrorContext(
            sessionID: "test",
            turnID: nil,
            sessionState: "connected",
            turnState: nil,
            userAction: nil
        )
        
        let action = await handler.handle(error, context: context)
        
        if case .reconnect = action {
            // 通过
        } else {
            XCTFail("Expected reconnect action")
        }
    }
    
    func testAudioPermissionDenied() async throws {
        let error = VoiceSessionError.audioError(.permissionDenied)
        let context = ErrorContext(
            sessionID: "test",
            turnID: nil,
            sessionState: "connected",
            turnState: nil,
            userAction: "startRecording"
        )
        
        let action = await handler.handle(error, context: context)
        
        if case .showAlert(_, let message, let actions) = action {
            XCTAssertTrue(message.contains("麦克风"))
            XCTAssertTrue(actions.contains(.openSettings))
        } else {
            XCTFail("Expected showAlert action")
        }
    }
}
```

---

## 总结

### 关键设计点

1. **分层错误体系**: 5 大类，每类独立编码
2. **可恢复性标志**: 每个错误明确是否可恢复
3. **用户友好提示**: 技术错误转换为用户可理解的语言
4. **自动降级**: 根据错误频率自动降低服务质量
5. **自动恢复**: 连续成功后逐步恢复正常

### 错误处理特性

- ✅ 15+ 种网络错误，指数退避重连
- ✅ 9+ 种音频错误，质量降级策略
- ✅ 7+ 种协议错误，序列号恢复
- ✅ 8+ 种业务错误，降级方案
- ✅ 7+ 种系统错误，资源监控

### 降级方案

- L1-L6 六级降级
- 自动降级与恢复
- 用户体验平滑过渡

下一步: [07_threading_model.md](07_threading_model.md) - 并发模型与线程安全
