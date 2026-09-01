# Client ASR 集成与使用指南

**版本**：V1.0  
**日期**：2026-09  
**定位**：说明 Client ASR 架构、三个实现类的选择、如何在 DI 容器中配置、以及测试策略

---

## 一、Client ASR 是什么

Client ASR（Automatic Speech Recognition）是**端侧语音识别**能力的抽象层，用于将 PCM 音频流转写为文本。

### 为什么需要 Client ASR

1. **降低服务端压力**：短语音（< 5s）可在设备端完成识别，无需回传
2. **降低延迟**：端侧识别通常 300-500ms 完成，比网络往返更快
3. **隐私保护**：敏感内容可选择不上传服务器
4. **离线能力**：Apple Speech 支持无网络识别（iOS 13+）

### 架构概览

```
ClientASRTranscriber (Protocol)
    ├── RawClientASRTranscriber         // Debug 桩实现，返回空字符串
    ├── AppleSpeechClientASRTranscriber // 基于 Apple Speech Framework
    └── VolcengineClientASRTranscriber  // 火山引擎 SDK（B14 待集成）
```

---

## 二、三个实现类

### 1. `RawClientASRTranscriber`

**用途**：Debug / 测试占位  
**行为**：消费 PCM 流但返回空字符串 `""`，模拟 ASR 不可用场景  
**何时使用**：
- 本地调试时想跳过 ASR 逻辑
- 集成测试需要确定性空结果
- 新功能开发时 ASR 依赖尚未就绪

```swift
#if DEBUG
container.clientASRTranscriber.register {
    RawClientASRTranscriber()
}
#endif
```

---

### 2. `AppleSpeechClientASRTranscriber`

**用途**：生产环境端侧识别（iOS 13+）  
**依赖**：
- `import Speech`
- `NSSpeechRecognitionUsageDescription` in Info.plist
- 用户授权：`SFSpeechRecognizer.requestAuthorization()`

**能力**：
- iOS 13+：基础端侧识别
- iOS 17+：增强准确率和性能
- 支持多语言（通过 `locale` 参数）

**错误处理**：
- `.notAvailable`：识别器不可用或不支持该语言
- `.authorizationDenied`：用户拒绝授权
- `.engineError(String)`：识别过程出错

**配置示例**：

```swift
// 默认中文简体
container.clientASRTranscriber.register {
    AppleSpeechClientASRTranscriber()
}

// 或指定其他语言
container.clientASRTranscriber.register {
    AppleSpeechClientASRTranscriber(locale: Locale(identifier: "en-US"))
}
```

**注意事项**：
- PCM 格式要求：16-bit, 16kHz, mono
- 识别器会在流结束后返回 `isFinal` 结果
- 建议短语音（< 10s），长语音可能超时或内存压力

---

### 3. `VolcengineClientASRTranscriber`

**用途**：火山引擎 ASR SDK（B14 待集成）  
**当前状态**：占位实现，抛出 `.notAvailable`  
**集成要求**（待完成）：
- 添加火山引擎 SDK 依赖（SPM / CocoaPods）
- 配置 `appID` 和 `token`
- 更新网络策略以允许火山引擎端点

**配置示例**（未来）：

```swift
container.clientASRTranscriber.register {
    VolcengineClientASRTranscriber(
        appID: "your-app-id",
        token: "your-token"
    )
}
```

**当前行为**：  
调用 `transcribe(pcm:)` 会消费流但抛出 `.notAvailable`，可用 `AppleSpeechClientASRTranscriber` 作为降级方案。

---

## 三、DI 容器配置

### 注册位置

在 `AppDependencies.swift` 或测试文件的容器初始化中注册：

```swift
import Factory

extension Container {
    var clientASRTranscriber: Factory<ClientASRTranscriber> {
        self { AppleSpeechClientASRTranscriber() }
            .singleton
    }
}
```

### 选择策略

**生产环境**：
- 优先使用 `AppleSpeechClientASRTranscriber`（成熟、零依赖）
- 火山引擎集成后可按需切换或分流

**Debug 环境**：
- 使用 `RawClientASRTranscriber` 快速验证流程
- 或使用 Apple Speech 但降低日志级别

**测试环境**：
- 单元测试：Mock `ClientASRTranscriber` 协议
- 集成测试：使用 `RawClientASRTranscriber` 保证确定性

---

## 四、使用示例

### 基础用法

```swift
let transcriber = Container.shared.clientASRTranscriber()

let pcmStream = AsyncStream<Data> { continuation in
    // 喂入 PCM 数据
    for chunk in pcmChunks {
        continuation.yield(chunk)
    }
    continuation.finish()
}

do {
    let transcript = try await transcriber.transcribe(pcm: pcmStream)
    print("识别结果：\(transcript)")
} catch ClientASRError.notAvailable {
    print("ASR 不可用，降级到服务端识别")
} catch ClientASRError.authorizationDenied {
    print("用户拒绝语音识别授权")
} catch {
    print("识别出错：\(error)")
}
```

### 错误降级

```swift
func transcribeWithFallback(pcm: AsyncStream<Data>) async throws -> String {
    do {
        return try await Container.shared.clientASRTranscriber()
            .transcribe(pcm: pcm)
    } catch ClientASRError.notAvailable, ClientASRError.authorizationDenied {
        // 降级到服务端识别
        return try await serverASR.transcribe(pcm: pcm)
    }
}
```

---

## 五、测试策略

### 1. 单元测试（协议 Mock）

```swift
final class MockClientASRTranscriber: ClientASRTranscriber {
    var mockResult: Result<String, Error> = .success("模拟文本")
    
    func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        // 消费流避免背压
        for await _ in pcm {}
        
        switch mockResult {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        }
    }
}

func testSpeechSessionWithMockASR() async throws {
    let container = Container()
    container.clientASRTranscriber.register {
        MockClientASRTranscriber()
    }
    
    // ... 测试逻辑
}
```

### 2. 集成测试（RawClientASRTranscriber）

```swift
func testClientASRIntegration() async throws {
    let container = Container()
    container.clientASRTranscriber.register {
        RawClientASRTranscriber() // 确定性空结果
    }
    
    let transcriber = container.clientASRTranscriber()
    let pcm = makeTestPCMStream()
    
    let result = try await transcriber.transcribe(pcm: pcm)
    XCTAssertEqual(result, "") // 预期为空
}
```

### 3. 手动测试（真实设备 + Apple Speech）

**前置条件**：
1. 在 Info.plist 添加 `NSSpeechRecognitionUsageDescription`
2. 首次运行时请求授权

**步骤**：
1. 配置 `AppleSpeechClientASRTranscriber`
2. 录制一段测试音频（16kHz, mono, 16-bit PCM）
3. 喂入 `transcribe(pcm:)` 并检查结果
4. 查看日志确认识别延迟（通常 300-500ms）

**Mock 设备测试**：  
参考 `docs/12_mock_device_测试支持说明.md`，可在模拟器中测试流程，但 Apple Speech 在模拟器上可能不可用（返回 `.notAvailable`）。

---

## 六、日志与监控

### Apple Speech 日志

`AppleSpeechClientASRTranscriber` 使用 `OSLog`：

```swift
private let logger = Logger(
    subsystem: "com.fluentwork.app",
    category: "AppleSpeechASR"
)
```

**关键日志点**：
- 初始化时检查 `recognizer.isAvailable`
- 识别开始和结束（含字符数）
- 错误（含错误描述）

### 监控指标（未来）

建议采集：
- 识别延迟（P50 / P95）
- 成功率 vs 降级率
- 不同语言的识别准确率（需人工标注）

---

## 七、常见问题

### Q1: 模拟器上无法识别

**A**: Apple Speech 在部分模拟器上不可用，使用真机测试或切换到 `RawClientASRTranscriber`。

### Q2: 识别结果为空但没报错

**A**: 可能是音频格式不匹配（确保 16-bit, 16kHz, mono）或音频过短（< 200ms）。

### Q3: 如何选择 Apple Speech vs 火山引擎

**A**: 
- Apple Speech：零成本、隐私友好、离线可用，但准确率取决于系统版本
- 火山引擎：可定制、准确率可能更高，但有网络依赖和成本

建议先用 Apple Speech 验证流程，后续按需集成火山引擎作为可选增强。

### Q4: 测试时如何避免真实识别

**A**: 使用 `RawClientASRTranscriber` 或 Mock 协议，见上文「测试策略」。

---

## 八、下一步

- [ ] B14：集成火山引擎 SDK 并实现 `VolcengineClientASRTranscriber`
- [ ] 补充多语言识别的集成测试
- [ ] 添加识别延迟和准确率的埋点
- [ ] 编写真机测试 Runbook（含授权流程）

---

**相关文档**：
- `docs/02_iOS架构实现约定.md` — DI 容器和测试隔离
- `docs/12_mock_device_测试支持说明.md` — 模拟设备测试
- B12 / B13 backend schema — client ASR 回灌字段
