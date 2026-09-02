# Client ASR 集成与使用指南

**版本**：V3.0（B14 完成）  
**日期**：2026-09  
**状态**：B14 完成后，Client ASR 协议及相关实现已从生产代码中移除。以下为历史说明。

> ⚠️ **已废弃**：B14 架构下 iOS 端不再使用 `ClientASRTranscriber` 协议。PCM 音频直接通过 `sendAudioPCM` 发送给后端 voice gateway，权威转写由 WSS `client.asr.transcription` 帧回传。此文档保留供历史参考。

---

## B14 最终架构

```
iOS (LiveAudioEngine)
        │ PCM (16kHz, mono, s16le)
        ▼
  [user.speech.start] ──────────── WSS frame
        │ PCM chunks → sendAudioPCM()
        ▼
  [user.speech.end(text: nil)] ─── WSS frame
        │
        ▼
Backend Voice Gateway (Volcengine Duplex)
  Doubao ASR Transcript ◄─────────────┐
        │                               │
        ▼                               │
  [client.asr.transcription] ←── WSS ──┘
        │
        ▼
  SpeechSessionMiddleware
        └─ dispatch .serverASRReceived(text:turnID:)  (liveTranscript 更新)
```

> **注意**: 中间件**不再**为 relay 帧调 `sendSpeechBoundary`。
> iOS VAD 触发的 `user.speech.end` 才是 backend 唯一认可的 turn 终点。
> Badge hit detection 走 backend `ProviderOutbound.ServerASRText` → `extractServerASRText`，
> iOS 无需重复推送文本。
> （之前版本的"再调一次 sendSpeechBoundary"会引发 ghost turn：16ms 后 backend 收到第二次
> user.speech.end，commit 空音频，60s 后超时，client 报 sockettransporterror error 3。）

### 关键变化（B13 → B14）

| 方面 | B13（已废弃） | B14（最终） |
|------|--------------|------------|
| ASR 引擎 | Apple Speech（端侧） | Volcengine Duplex（服务端） |
| PCM 处理 | 缓冲后调用本地转写器 | 直接转发 `sendAudioPCM` |
| `sendSpeechBoundary(text:)` | 等待本地 ASR 结果 | 发送 `nil`，由 backend 从 `ServerASRText` 取文本做 badge detection |
| iOS 离线能力 | 支持 | 不支持（需网络） |
| 协议抽象 | `ClientASRTranscriber` | **已移除** |

---

## 协议和实现（已移除，仅供参考）

以下文件已在 B14 完成后从代码库中移除：

- `RawClientASRTranscriber.swift` — Debug 占位实现
- `ServerRelayASRTranscriber.swift` — B14 服务端中继占位

保留的协议定义（`ClientASRTranscriber.swift`）和实现（`AppleSpeechClientASRTranscriber.swift`、`VolcengineClientASRTranscriber.swift`）不再被中间件调用，可在未来按需复用。

---

## 移除前的协议定义（供参考）

```swift
public protocol ClientASRTranscriber: Sendable {
    func transcribe(pcm: AsyncStream<Data>) async throws -> String
}

public enum ClientASRError: Error, Sendable {
    case notAvailable
    case timeout
    case unsupportedFormat
    case engineError(String)
    case authorizationDenied
}
```

---

## 测试策略（B14 完成前）

在 B14 完成前，测试注入 `RawClientASRTranscriber()` 作为确定性占位：

```swift
func makeTestContainer(...) -> Container {
    let container = Container()
    container.reset()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }
    container.tracker.register { tracker }
    // B14: transcriber 不再被中间件调用，注入任意实现均可
    container.clientASRTranscriber.register { RawClientASRTranscriber() }
    return container
}
```

---

## WSS 帧设计

### `client.asr.transcription`（Server → Client）

```json
{
  "type": "client.asr.transcription",
  "text": "用户说的内容",
  "turn_id": "turn-1"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `type` | string | 帧类型常量 |
| `text` | string | 豆包返回的完整转写文本 |
| `turn_id` | string | 对应语音段的 turn 标识 |

---

**相关文档**：
- `docs/37_FluentWork-B14_Client_ASR_Relay_Architecture.md` — B14 架构设计
- `docs/02_iOS架构实现约定.md` — DI 容器和测试隔离
