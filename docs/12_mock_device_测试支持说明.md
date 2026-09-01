# Mock Device / Mock Transport 测试支持说明

**对应背景**：`docs/11_I13_iOS_backend_wss联调_runbook.md` §3 中标注需要真机 + Charles 抓 WSS 帧的几个用例（Case 1 / 2 / 6.1-6.3）在无 Charles 环境下可由本套 mock 设施覆盖等价信号路径。本文盘点现有 mock 资产、给出每个 mock 的协议归属、典型用法，以及 runbook 用例 → mock 测试的对应表。

**作用范围**：仅限 `fluentwork-ios` 仓。`fluentwork-backend` mock 设施（`stubBlockSource` / `MemoryStore` / 各种 `realXxxConn`）见 `docs/20_B12_badge_emit_问题修复说明.md`。

---

## 1. 设计目标

1. **不依赖真机**：所有 WSS / HTTP / Storage / Time / ID 行为都可在 `swift test` 里覆盖
2. **不依赖 Charles / Proxyman**：mock 直接把 frame 注入 `AsyncStream<SocketTransportEvent>`，不需要抓包
3. **不依赖环境变量**：mock 是协议实现，DI 通过 `Container.shared.reset()` 替换
4. **可同时验证 reducer / middleware / store / 客户端 / 协议解码** 五层

不覆盖：

- 真音频采集路径（`AVAudioEngine` 麦克风输入）
- 真 Opus 解码（依赖 Volcengine SDK，B13 引入）
- 真蓝牙路由切换（`AVAudioSession.routeChange`）
- 真网络抖动 / 丢包（这部分 iOS 不模拟，由 backend chaos test 覆盖）

---

## 2. 生产形态 mock（`Shared/`，可跨测试复用）

> 这些类型写在 `Shared/` 下、被 production 代码导入，但只有 `*Protocol*` 暴露给业务。测试时通过 DI 替换为 mock 实现。

| Mock 类型 | 协议 | 路径 |
|---|---|---|
| `InMemorySocketTransport` | `SocketTransportProtocol` | `Shared/FluentWorkNetworking/Socket/InMemorySocketTransport.swift` |
| `StubNetworkClient` | `NetworkClientProtocol` | `Shared/FluentWorkNetworking/NetworkClient.swift` |
| `StubNetworkMonitor` | `NetworkMonitorProtocol` | `Shared/FluentWorkNetworking/NetworkMonitor.swift` |
| `InMemorySecureStorage` | `SecureStorageProtocol` | `Shared/FluentWorkCore/Storage/SecureStorage.swift` |
| `InMemoryCorpusCacheStore` | `CorpusCacheStoreProtocol` | `Shared/FluentWorkCore/Storage/CorpusCacheStore.swift` |
| `InMemoryCorpusOutboxStore` | `CorpusOutboxStoreProtocol` | `Shared/FluentWorkCore/Storage/CorpusOutboxStore.swift` |
| `InMemoryCorpusSyncMetadataStore` | `CorpusSyncMetadataStoreProtocol` | `Shared/FluentWorkCore/Storage/CorpusSyncMetadataStore.swift` |
| `StubDailyReadAudioPlayer` | `DailyReadAudioPlayerProtocol` | `Shared/FluentWorkCore/Services/DailyReadAudioPlayer.swift` |
| `FixedClock` | `ClockProtocol` | `Shared/FluentWorkCore/Dependencies/InjectableTime.swift` |
| `FixedIDGenerator` | `IDGeneratorProtocol` | `Shared/FluentWorkCore/Dependencies/InjectableTime.swift` |

非 mock 但常被测试用作占位：

- `PlaceholderAudioEngine` — `AudioEngineProtocol` 占位（不发事件，不出 PCM），用于不需要验证 audio 路径的 reducer 单测
- `StaticBootstrapClient` — `BootstrapClientProtocol` 固定 snapshot，用于 bootstrap reducer 单测
- `RawPCM16FrameDecoder` — `WSAudioFrameDecoder` 直接把 opusPayload 当 PCM16 透传，是 B13 启用前的 fallback 解码器
- `VolcengineOpusFrameDecoder` — `WSAudioFrameDecoder` 真解码器 stub，B13 SDK 接入前 decode 抛 `notAvailable`

---

## 3. 内联 mock（`Tests/`，每个测试套就近定义）

| Mock 类型 | 协议 | 测试文件 |
|---|---|---|
| `MockBootstrapClient` | `BootstrapClientProtocol` | `Tests/.../AppBootstrapMiddlewareTests.swift` |
| `StubCorpusClient` | `CorpusClientProtocol` | `Tests/.../CorpusFeatureTests.swift` |
| `StubSpeechSessionClient` | `SpeechSessionClientProtocol` | `Tests/.../ReviewFeatureTests.swift`、`SpeakingRoomSessionWiringTests.swift` |
| `StubDailyReadAPIClient` | `DailyReadAPIClientProtocol` | `Tests/.../DailyReadAudioPlayerTests.swift`、`DailyReadMiddlewareTests.swift`、`DailyReadClientTests.swift` |
| `StubDailyReadClient` | `DailyReadClientProtocol` | `Tests/.../DailyReadAudioPlayerTests.swift`、`DailyReadMiddlewareTests.swift` |
| `StubSessionAPIClient` | `SessionAPIClientProtocol` | `Tests/.../DailyReadClientTests.swift` |
| `InMemoryAuthTokenStore` | `AuthTokenStoreProtocol` | `Tests/.../DailyReadClientTests.swift` |
| `StubAudioEngine` | `AudioEngineProtocol` | `Tests/.../SpeakingRoomSessionWiringTests.swift` |
| `FailingSessionStartTransport` | `SocketTransportProtocol` | `Tests/.../SpeechSessionClientTests.swift` |

约定：

- 内联 mock 用 `private final class` / `private actor` / `private struct`，避免跨文件污染
- 命名统一 `Stub*` / `Mock*` / `InMemory*` / `Failing*`，与协议前缀对齐
- 实现 `Sendable` 时使用 `@unchecked Sendable`（多数 mock 持有可变状态但不需要严格 actor 隔离）

---

## 4. DI 替换模式（FactoryKit）

### 4.1 构造器注入（首选）

多数 service 都接受依赖作为构造参数。测试直接传 mock，不需要 reset 容器：

```swift
let transport = InMemorySocketTransport()
let storage = InMemorySecureStorage()
let tokenStore = SecureAuthTokenStore(
    storage: storage,
    idGenerator: FixedIDGenerator(value: UUID(uuidString: "...")!)
)
let client = DefaultSpeechSessionClient(
    api: SessionAPIClient(
        network: StubNetworkClient { target in
            switch target.path {
            case "/auth/guest": return guestJSON
            case "/sessions": return sessionJSON
            default: return Data()
            }
        },
        baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
    ),
    tokens: tokenStore,
    transport: transport
)
```

### 4.2 容器注入（middleware / store 测试需要）

`AppStoreFactory.make(container:)` 通过 `Container.shared` 解析依赖。middleware 测试模式：

```swift
let container = Container()
container.reset()
let transport = InMemorySocketTransport()
container.socketTransport.register { transport }

let store = AppStoreFactory.make(container: container)
store.dispatch(.speakingRoom(.session(.sessionStartTap)))

// 然后通过 transport 注入事件
await transport.emitControl(.feedbackBadge(badge: "表达自然", phraseBlockID: "block-1", tier: .soft))

#expect(store.state.speakingRoom.badgeHits == 1)
```

约定：

- 每个测试开头 `container.reset()`，结尾 `defer { container.reset() }`
- `container.reset()` 不传 `Container.shared`（除非确实需要覆盖全局），避免污染同进程其他测试
- 仅覆盖测试需要的字段；其它依赖由 `AppStoreFactory` 自身装配的 mock 实现兜底

### 4.3 直接赋值 mock 实例

部分 store / service 持有 `var` 属性（如 `SpeechSessionMiddleware.speechClient`），测试可直接 `service.speechClient = StubSpeechSessionClient()`。这种替换没有协议抽象成本，但耦合度高，只在确实需要"切一半"的情况下用。

---

## 5. WSS 测试模式（核心）

`InMemorySocketTransport` 是 runbook §3 全部用例的 mock 落点。

### 5.1 能力清单

| 操作 | 方法 | 用途 |
|---|---|---|
| 记录连接 | `connectCalls: [(url, sessionID, ticket)]` | 断言连接参数正确（Case 1 turn_id 之前的 auth/ticket 校验） |
| 记录控制帧 | `sentControlFrames: [WSControlFrame]` | 断言 iOS 发出的 `user.speech.start` / `user.speech.end` 等 |
| 记录音频 | `sentAudioPayloads: [Data]` | 断言 PCM 上行 |
| 注入状态事件 | `connect()` / `disconnect()` 内部 yield | 驱动 state machine 流转 |
| 注入控制帧 | `emitControl(_ frame: WSControlFrame)` | 模拟 backend → iOS（`feedback.badge` 等） |
| 注入音频帧 | `emitAudio(_ frame: WSAudioFrame)` | 通过 `AudioFrameDropGate` 验证 drop 行为 |
| 注入失败 | `emitFailure(_ error: SocketTransportError)` | 触发 reconnect 路径 |
| 注入打断 | `markInterrupted()` | 触发 drop-gate |

`emitAudio` 内部走和 production `URLSessionWebSocketTask` 一样的 `AudioFrameDropGate`，所以 drop 行为是真验证过的（不是"假装"drop）。

### 5.2 典型用例映射

| runbook §3 用例 | mock 测试 | 关键 mock 调用 |
|---|---|---|
| Case 1 turn_id 单调 | `defaultSpeechSessionClientSendsMonotonicTurnIDsAcrossMultipleTurns` | `transport.connect` + `client.sendSpeechBoundary(started:false, turnID:"turn-1"/"turn-2")` |
| Case 2 后端 hit + dedupe | `badgeFeedbackDedupeHonorsTimeWindowTTL` | `state.ingest(...)` 直接驱动 BadgeFeedback state 三次（同 key / 跨 TTL / 跨 turn） |
| Case 3 iOS dedupe 镜像 | `badgeFeedbackDedupeRespectsPhraseBlockID` | 同上 |
| Case 4 schema mirror | 已有 schema 解析测试集 | `JSONDecoder().decode(WSControlFrame.self, ...)` |
| Case 5 ASR 分段埋点 | middleware 测试已覆盖 transport event → Tracker emit |
| Case 6 iOS local state 更新 | `speechSessionMiddlewareConsumesTransportBadgeEvents` 等 | `transport.emitControl(.feedbackBadge(...))` |
| §4 transport 兜底 | `speechSessionMiddlewareStartsReconnectWindowOnDisconnect` 等 5 个 | `transport.disconnect()` / `transport.emitFailure(...)` |

Case 6.1-6.3（badge 触发后 React/SwiftUI 渲染）目前由单元测试覆盖 reducer + state，纯 UI 渲染截图需要真机（Xcode Preview + smoke runbook 覆盖）。

---

## 6. HTTP 测试模式

`StubNetworkClient` 接 `NetworkClientProtocol`，是闭包工厂：

```swift
let api = SessionAPIClient(
    network: StubNetworkClient { target in
        switch target.path {
        case "/auth/guest": return guestJSON
        case "/sessions": return sessionJSON
        case let p where p.hasPrefix("/sessions/") && p.hasSuffix("/messages"):
            return postMessageJSON
        default:
            Issue.record("unexpected \(target.path)")
            return Data()
        }
    },
    baseURL: URL(string: "http://127.0.0.1:8080/api/v1")!
)
```

约定：

- 未匹配的 path 用 `Issue.record` 标记（Swift Testing 会 fail 而不是 pass）
- 返回 JSON 用 literal 字面量 + `Data(...utf8)`，方便比对
- 不需要 Stub URLProtocol — 所有出网都走 `NetworkClientProtocol`，可在 DI 层拦截

---

## 7. Audio / Time / ID 测试模式

### 7.1 Audio

| 路径 | mock | 用法 |
|---|---|---|
| AudioEngine 捕获路径 | `StubAudioEngine`（私有） | `await audioEngine.snapshotPlayedFrames()` 断言播放帧列表 |
| AudioEngine 占位 | `PlaceholderAudioEngine`（共享） | 不验证 audio 行为的 reducer / middleware 测试 |
| Opus 解码 | `RawPCM16FrameDecoder` | 不需要真 Opus 解码时直接透传 |
| Opus 解码（不可用） | `VolcengineOpusFrameDecoder` | 测 fallback / 升级路径（throw `notAvailable`） |

### 7.2 Time / ID

```swift
let clock = FixedClock(now: Date(timeIntervalSinceReferenceDate: 1000))
let idGen = FixedIDGenerator(value: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
```

任何依赖"现在时间"或"生成 UUID" 的代码都接这两个，测试可完全确定时间序列。

---

## 8. 已有 mock 覆盖矩阵（runbook §3 用例）

| runbook 用例 | mock 覆盖 | 真机 / Charles 必要性 |
|---|---|---|
| Case 1 turn_id 单调 | ✅ `defaultSpeechSessionClientSendsMonotonicTurnIDsAcrossMultipleTurns` | 否 |
| Case 2 hit + dedupe | ✅ `badgeFeedbackDedupeHonorsTimeWindowTTL` | 否（iOS 侧）；后端侧由 `TestBadgeEmitter_*` 覆盖 |
| Case 3 iOS dedupe 镜像 | ✅ `badgeFeedbackDedupeRespectsPhraseBlockID` | 否 |
| Case 4 schema mirror | ✅ `wssControlFramesSchemaHas*` 系列 | 否 |
| Case 5 ASR 分段埋点 | ✅ middleware 测试 + Tracker capture | 否 |
| Case 6 iOS local state | ✅ `speechSessionMiddlewareConsumesTransportBadgeEvents` 等 | 否（仅 UI 渲染截图需真机） |
| Case 6.1-6.3 React 渲染 | ❌ | 是 — 走 smoke runbook (`Scripts/smoke-iphone17pro.sh`) |
| 真音频采集 / 蓝牙路由 | ❌ | 是 — smoke runbook |

**结论**：runbook §3 除 Case 6.1-6.3 之外，mock 可覆盖全部等价信号。Charles 不是前置条件。

---

## 9. 扩展指南（加新 mock）

1. **判断是否需要新 mock**：先查 §2 / §3 表，确认没有可复用的
2. **协议抽象**：在 `Shared/.../Protocols.swift` 或对应模块加 protocol；不要给原类型加可重写方法
3. **命名**：`*InMemory*` 用于存储类（无副作用）、`*Stub*` 用于可注入行为的网络/客户端类、`*Mock*` 用于断言式 stub（可记录调用）、`*Failing*` 用于错误路径
4. **位置**：跨测试复用放 `Shared/`；仅单文件用放 `Tests/.../*Tests.swift` 内部
5. **Sendable**：actor / final class 都标 `@unchecked Sendable`；纯值类型 struct 不需要
6. **DI 注册**：在 `AppDependencies.swift` 加 `Container.*.register { DefaultImpl() }`；mock 不在 `Shared/` 里注册，由测试自己注册
7. **测试覆盖**：至少一个 happy path + 一个失败 path

---

## 10. 与 §6 文档债 / MR 的对应

| 文档 / MR | mock 设施 |
|---|---|
| meta#14 `source=ios` 注释 | 依赖 `Tracker`（iOS 固定 `source=ios`），由 middleware 测试覆盖 |
| infra#7 `phrase_block_id` 例 | 依赖 `WSAudioFrameDecoder` / `BadgeFeedback`，由 Case 2 / Case 3 mock 测试覆盖 |
| runbook §6 tick | 本文档直接对应 |

---

## 11. 已知缺口 / 后续 ticket

| 缺口 | 影响 | 后续 |
|---|---|---|
| 没有 `URLSessionWebSocketTask` mock（直接用真协议会启动端口监听） | Case 6.1-6.3 仍需真机 / Charles | B13 后可加 `LoopbackSocketTransport`，监听真 URLSessionWebSocketTask 端口 |
| `AVAudioEngine` 路径没 mock | 真音频采集 / 蓝牙路由需 smoke | smoke runbook 保留 |
| `OpusDecoder` 仅 stub | B13 SDK 接入前 fallback 路径已覆盖 | B13 完成时替换 `VolcengineOpusFrameDecoder` |
| 没有 chaos / 网络抖动模拟 | WSS reconnect 路径的 long-tail 行为只能间接覆盖 | 视 backend chaos test 覆盖范围决定是否补 |