# iOS ↔ Backend 联调 Runbook — 说话间 WSS + Badge Dedup

> 范围：iOS 说话间（`fluentwork-ios`）↔ 后端 voice-gateway（`fluentwork-backend/internal/voicegateway`）
> 适用：B11 / B12 / B14 联合发版前的最后一轮自测
> 联调对象：iOS 工程师 + 后端 voice-gateway 维护者
> 必备基础：WSS 控制帧协议、ASR 路径、Badge dedupe 语义

---

## 1. 这次联调关注什么

本次联调只覆盖**新引入的 wire-format 字段**：

| 方向 | 帧 | 字段 | 用途 |
|---|---|---|---|
| iOS → backend | `user.speech.end` | `turn_id` | 后端 BadgeEmitter 的 dedupe key（`session\|turn\|phrase_block`） |
| iOS → backend | `user.speech.end` | `text` | 客户端 ASR 文本（B13 启用；当前 day-one 传 `nil`，走 server-side ASR） |
| backend → iOS | `feedback.badge` | `phrase_block_id` | 语料库 ID；iOS 用它做 dedupe 扩展键 |
| backend → iOS | `feedback.badge` | `tier` | 视觉权重（`soft` / `highlight` / `celebrate`） |
| iOS observability | `speech_turn_ended` | `turn_id` / `source` / `stage` | schema-driven 分段埋点，跨 iOS / backend 对齐 |

> **分段记录**：所有跨端 ASR 段都按 `session_id` + `turn_id` 切；schema 真源在 `fluentwork-infra/schemas/` 与三仓 mirror（`fluentwork-ios/Shared/FluentWorkCore/Resources/Schemas/`、`fluentwork-backend/schemas/`）。

---

## 2. 启动前自检

### 2.1 三仓 schema 同步

```bash
# 1. iOS 仓 mirror 同步自检
cd fluentwork-ios
swift test --filter wssControlFramesSchemaHasUserSpeechEndTurnAndText
swift test --filter wssControlFramesSchemaHasFeedbackBadgePhraseBlockAndTier
swift test --filter speechObservabilitySchemaHasTurnIDAndSource

# 2. 后端 Go 用同一份 embed schema
cd ../fluentwork-backend
go test ./internal/voiceproto/ -run TestSchemaFilePresent
go test ./internal/voiceproto/ -run TestFeedbackBadgeFrameDecode
```

预期：

- 全部 pass
- 任一 fail → 三仓 schema 没同步，先跑：

  ```bash
  bash Scripts/sync-shared-schemas.sh
  ```

### 2.2 后端起 dev 模式 + 打开 hit-detection

```bash
cd fluentwork-backend
# 启用 B12 BadgeEmitter（默认开启；如需显式确认）
export VOICE_HIT_DETECT=1
go run ./cmd/voice-gateway
```

期望日志：

```
[component=voicegateway.handler] voice session ready session_id=... user_id=...
```

### 2.3 iOS 仓指向 dev backend

`fluentwork-ios` 的 `AppEnvironment.current` 需指向本机：

```swift
apiBaseURL = URL(string: "http://127.0.0.1:8080/api/v1")!
wssBaseURL = URL(string: "ws://127.0.0.1:8080/v1/voice")!
```

### 2.4 工具

- Charles / Proxyman：抓 WSS 控制帧（记得勾选 WebSocket payload）
- Console.app：过滤 `process:FluentWorkHost`，搜 `[Tracker] speech_turn_ended`
- 后端日志：`slog` 默认 JSON 输出，过滤 `component=voicegateway.badge_emitter` / `voicegateway.handler`

---

## 3. 联调用例

### Case 1 — turn_id 在 iOS 端单调递增

**Mock 覆盖**（无 Charles 时）：

```bash
swift test --filter defaultSpeechSessionClientSendsMonotonicTurnIDsAcrossMultipleTurns
```

测试驱动 `InMemorySocketTransport` + `DefaultSpeechSessionClient`，直接断言两个连续的 `user.speech.end` 帧携带 `turn_id: "turn-1"` → `"turn-2"`。

**真机 + Charles 步骤**：iOS `user.speech.end` 帧携带的 `turn_id` 从 `"turn-1"` 开始，按完成顺序递增。

步骤：

1. iOS 启动说话间，按住说话一次（VAD 触发）
2. 等到 AI 回复结束，再按住说话一次
3. 抓 WSS 帧，过滤 `type=user.speech.end`

预期：

```json
{"type": "user.speech.end", "turn_id": "turn-1"}   // 第一次
{"type": "user.speech.end", "turn_id": "turn-2"}   // 第二次
```

后端日志：

```
voicegateway.handler voice user speech frame session_id=... type=user.speech.end stage=asr
```

**断言**：

- 两次 `user.speech.end` 都带 `turn_id`（schema 允许 null，但 iOS 实现必须带）
- iOS 端 `console` 能看到 `[Tracker] speech_turn_ended ["turn_id": "turn-1", "source": "ios", "stage": "asr"]`（注意：这是 iOS 自己打印的埋点，不是后端）

### Case 2 — 后端 hit-detection 命中 + dedupe 正确

**Mock 覆盖**（无 Charles 时）：

```bash
swift test --filter badgeFeedbackDedupeHonorsTimeWindowTTL
swift test --filter backendFeedbackBadgeJSONDecodesIntoStoreEntries
```

前一条直接驱动 `BadgeFeedback.state.ingest()` 三次（TTL 内重复 → 1 条、TTL 过期 → 2 条、跨 turn_id → 3 条）；后一条用后端 dev-echo e2e 产出的真实 JSON 帧走 decode → middleware → store。Backend 侧的完整 WSS 真帧证据：

```bash
cd fluentwork-backend
go test ./internal/voicegateway/ -run TestDevEcho_EndToEnd_FiresBadgeOnSeededCorpus -count=1
```

**真机 + Charles 步骤**：同一 (session, turn, phrase_block) 的命中只产生一次 `feedback.badge`，跨 turn 不 dedupe。

步骤：

1. iOS 端准备一段命中语料库 phrase block 的口播（参考语料：`/corpus/phrase-blocks/...`）
2. 第一次说：期待 `feedback.badge` 命中并显示
3. **同一 turn 内**（不要等 AI 回复）再说一次相同的句子
4. 抓帧

预期：

- 同一 turn 内的第二次不产生新 `feedback.badge`（LRU 5s 内 dedupe）
- 跨 turn（AI 回复后再来一次）会产生新 `feedback.badge`，但 `turn_id` 是新的
- 后端日志：

  ```
  feedback.badge emitted session_id=... turn_id=turn-1 phrase_block_id=block-X score=0.9
  ```

**断言**：

- `feedback.badge.tier` 是 enum 之一（`soft` / `highlight` / `celebrate`），不出现空值或拼写错（`Highlight` / `SOFT` 等）
- `phrase_block_id` 永远非空（`NewFeedbackBadge` 在 phraseBlock 为空时跳过 emit）
- 跨 turn 的 `turn_id` 是新 turn，不是上一轮

### Case 3 — iOS 端 dedupe 镜像 schema-driven

**目标**：iOS `BadgeFeedback` 层按 `(badge, turn_id, phrase_block_id, time-window)` dedupe，与后端 dedupe key 对齐。

步骤：

1. iOS 端快速连按「Badge Hit」debug 按钮（HostRootView 有这条入口），发出 3 次同一 `(badge, turn_id)`
2. 等 5s，再点 1 次
3. 观察 iOS state

预期：

- 前 3 次只有 1 个 entry 落进 `state.badgeFeedback.entries`（dedupe）
- 第 4 次（5s 后）新增 entry
- 抓 WSS 帧：`feedback.badge` 是 backend→iOS 单向，不会因为 iOS 重复 emit

**断言**：

```swift
// iOS 测试覆盖：
- badgeFeedbackDedupeRespectsPhraseBlockID
- speakingRoomBadgeHitWithEnrichmentIsForwardedToBadgeFeedbackIngest
- backendFeedbackBadgeJSONDecodesIntoStoreEntries  // 真实帧进入 entries 且 turnID 保留
```

### Case 4 — Schema mirror 与 wire-format 同步

**目标**：iOS 在 runtime 收到的 `feedback.badge` 不会因为 schema 缺字段导致 decode 失败。

步骤：

1. 抓 backend 推过来的 `feedback.badge` raw 帧
2. 比对三处 schema：

   - `fluentwork-infra/schemas/transport/wss-control-frames-v1.json`
   - `fluentwork-ios/Shared/FluentWorkCore/Resources/Schemas/wss-control-frames-v1.json`
   - `fluentwork-backend/schemas/transport/wss-control-frames-v1.json`

预期：

- 三处 `$defs.feedbackBadge.properties` 都含 `phrase_block_id` 和 `tier`（enum = `["soft", "highlight", "celebrate"]`）
- 三处 mirror 字节级一致（含 `session_id` / `turn_id` / `dedupe_key` 可选字段）
- iOS 的 `WSControlFrame` decode 成功，`phraseBlockID` / `tier` / `turnID` 都解码

**Mock 覆盖**（wire JSON 解码契约）：

```bash
swift test --filter feedbackBadgeDecodesBackendWireFrame
swift test --filter feedbackBadgeMissingTierFallsBackToNil
swift test --filter feedbackBadgeMissingTurnIDDecodesAsNil
swift test --filter feedbackBadgeRejectsMisspelledTier
```

**如果 iOS 收到 `feedback.badge` 但 store 没更新**：

- 看 HostRootView badgeHits 计数有没有变
- 跑 `swift test --filter speechSessionMiddlewareConsumesTransportBadgeEvents`

### Case 5 — ASR 分段埋点

**目标**：iOS 每个 turn 结束都通过 `Tracker` 发出 `speech_turn_ended`，且字段对得上 schema。

步骤：

1. iOS 启动说话间，按住说话一次
2. 在 Console.app 过滤 `speech_turn_ended`

预期：

```
[Tracker] speech_turn_ended ["turn_id": "turn-1", "source": "ios", "stage": "asr"]
[Tracker] speech_turn_ended ["turn_id": "turn-2", "source": "ios", "stage": "asr"]
```

**断言**：

- `turn_id` 跟 WSS `user.speech.end` 帧的 `turn_id` 一致
- `source=ios` 永远是这个值（backend 端用 `source=voice_gateway` / `source=worker`）
- `stage=asr` 是 iOS 端的固定标签，对应 schema 的 `stage` 字段
- 这条埋点对应的是 iOS 端 `.vadSpeechEnd` 事件触发点；后端的同 turn 埋点用 `speech_turn_ended` + `source=voice_gateway`，两个 source 可以 join

### Case 6 — 异常路径

#### 6.1 后端没填 tier

backend 旧版本（pre-B12）会发 `feedback.badge` 但不带 `tier`。iOS 必须 fallback 到 `.unknown`，仍能显示 badge。

抓帧 → `tier` 字段缺失 → iOS 端 entry 的 `tier` 应为 `BadgeFeedEntry.Tier.unknown`。

```bash
swift test --filter backendPreB12FeedbackBadgeJSONLandsWithUnknownTier
```

#### 6.2 后端 tier 拼写错（`Soft` / `SOFT`）

iOS 的 `FeedbackBadgeTier` 是严格 enum，decode 会失败 → 整条 `feedback.badge` 丢失。

期望日志：iOS console 有 `WSControlFrameCodingError.unknownType` 或 `DecodingError`。**这是后端 bug，必须修。**

```bash
swift test --filter feedbackBadgeRejectsMisspelledTier
```

#### 6.3 客户端 ASR 文本回灌（`text` 字段）

当前 day-one 路径 iOS 永远传 `text: nil`（走 server-side ASR）。如果 B13 接入 Volcengine Opus SDK + 客户端 ASR，需要在 `DefaultSpeechSessionClient.sendSpeechBoundary` 把客户端 ASR transcript 灌到 `text`。

**联调前不要打开客户端 ASR 路径**，避免 trigger 误判。

---

## 4. 联调时如果出问题的排查路径

### 4.1 iOS 发的 `user.speech.end` 没有 `turn_id`

- 检查 `SpeechSessionMiddleware.swift` 是否用了 `TurnCountBox` 把当前 count 透传到 audio loop
- iOS test：`speechSessionMiddlewareForwardsTurnIDToSpeechBoundary` 必须 pass
- 看 console 的 `[Tracker] speech_turn_ended` 有没有该 turn 的 entry

### 4.2 iOS 收到 `feedback.badge` 但 store 不更新

- 抓帧 raw，确认 `type` 是 `feedback.badge`（拼写准确）
- 看 `WSControlFrame.swift` 的 `feedbackBadge` decode 路径有没有 `phraseBlockID` / `tier`
- 跑 `swift test --filter feedbackBadgeMapsToBadgeHit` 确认 mapper 还在
- 跑 `swift test --filter speakingRoomTransportBridgeBridgesSocketReadyAndBadge` 确认 bridge 把 transport action 转成 `SpeakingRoomAction.badgeHit(...)`

### 4.3 iOS 端 entry 的 tier 是 `.unknown` 但 backend 发的是 `highlight`

- 这是 `BadgeFeedEntry.Tier.from(transport:)` 的映射。检查 `BadgeFeedbackFeature.swift`：

  ```swift
  case .soft: return .badgeOnly
  case .highlight: return .nextTurnConfirm
  case .celebrate: return .sameTurnConfirm
  ```

  确认 wire tier 真的是 `highlight`（注意大小写）

### 4.4 backend dedupe 不生效（同一 turn 重复 emit badge）

- 检查 `voicegateway/badge_emitter.go` 的 `dedupeLRU.Allow()` 是否被调用
- `dedupe_key` 字段在 raw 帧里要包含 `session|turn|phrase_block` 三段，缺一段 `NewFeedbackBadge` 会拒绝 emit
- iOS 端 `turn_id` 必须每次带（不能空），否则 backend fallback 到 `turnID = sessionID`，会过度 dedupe

### 4.5 schema 三处不一致

```bash
# 1. infra 真源
cat fluentwork-infra/schemas/transport/wss-control-frames-v1.json

# 2. iOS mirror
cat fluentwork-ios/Shared/FluentWorkCore/Resources/Schemas/wss-control-frames-v1.json

# 3. backend embed
cat fluentwork-backend/schemas/transport/wss-control-frames-v1.json
```

任一对不上 → 跑 `fluentwork-ios/Scripts/sync-shared-schemas.sh` 重新拉。

### 4.6 iOS test 全 fail / 部分 fail

```bash
cd fluentwork-ios
swift test 2>&1 | grep -E "✘|fail" | head
```

主要新增/改动的 test：

- `wssControlFramesSchemaHasUserSpeechEndTurnAndText`
- `wssControlFramesSchemaHasFeedbackBadgePhraseBlockAndTier`
- `speechObservabilitySchemaHasTurnIDAndSource`
- `speechSessionMiddlewareForwardsTurnIDToSpeechBoundary`
- `speechSessionMiddlewareEmitsSchemaAlignedTurnEndedEvent`
- `speakingRoomBadgeHitWithEnrichmentIsForwardedToBadgeFeedbackIngest`
- `badgeFeedbackDedupeRespectsPhraseBlockID`
- `badgeFeedEntryTierFromTransportMapping`
- `feedbackBadgeMapsToBadgeHit`
- `speakingRoomActionBridgesSocketReadyAndBadge`
- `feedbackBadgeDecodesBackendWireFrame`
- `feedbackBadgeMissingTierFallsBackToNil`
- `feedbackBadgeMissingTurnIDDecodesAsNil`
- `backendFeedbackBadgeJSONDecodesIntoStoreEntries`
- `backendPreB12FeedbackBadgeJSONLandsWithUnknownTier`

---

## 5. 联调通过的硬标准

| Case | 必须 |
|---|---|
| 1. turn_id 单调递增 | ✓ |
| 2. dedupe 跨 turn 不误杀 | ✓ |
| 3. iOS 端 dedupe 包含 phrase_block_id | ✓ |
| 4. schema 三处同步 | ✓ |
| 5. `speech_turn_ended` 埋点跟 `user.speech.end.turn_id` 一致 | ✓ |
| 6. 异常路径（tier 缺失 / 拼写错）iOS 不崩 | ✓ |

任一不通过 → 阻塞发版，PR 不 merge。

---

## 6. 联调后要 update 的文档

- [x] `fluentwork-ios/docs/05_第二波开发范围与任务清单.md` §I11 / I12 / I13
- [x] `fluentwork-backend/docs/20_B12_badge_emit_问题修复说明.md`（追加 turn_id 章节）
- [x] `fluentwork-meta/docs/30_技术方案/36_FluentWork可观测性与事件Schema设计草案.md` 加 iOS `source=ios` 注释
- [x] `fluentwork-infra/docs/observability/00_FluentWork可观测性与事件Schema设计.md` 加 `phrase_block_id` 例
- [x] `fluentwork-ios/docs/12_mock_device_测试支持说明.md` mock 资产全量盘点 + Case 1/2/3 mock 覆盖表（由 `docs/I13-mock-case12-plus-mock-guide` MR 落地）

---

## 7. 关联文档

- iOS 架构约定：`fluentwork-ios/docs/02_iOS架构实现约定.md` §2.2 + §6.3
- WSS schema 真源：`fluentwork-infra/schemas/transport/wss-control-frames-v1.json`
- 后端 B12：`fluentwork-backend/docs/20_B12_badge_emit_问题修复说明.md`
- 后端 B14 ASR：`fluentwork-backend/docs/07_B14_D3_ASR实现说明.md`
- 跨端事件：`fluentwork-infra/docs/observability/00_FluentWork可观测性与事件Schema设计.md`
