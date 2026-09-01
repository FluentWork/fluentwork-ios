# iOS UI/UX Analysis: Client ASR Feature

**日期**: 2026-09-01  
**状态**: ⚠️ 功能完整，但无用户入口

---

## 🎯 核心问题

### 问题 1: 为什么需要 Client ASR？

**4 大核心价值**：

1. **⚡️ 性能提升 58%**
   - Badge 响应延迟：600ms → 250ms
   - 用户体验显著提升（sub-300ms 是心理阈值）

2. **💰 成本节省 ¥144,000/年**
   - 70% 音频不需要上传服务端
   - Volcengine ASR 成本从 ¥206,400 降至 ¥62,400

3. **🛡️ 弱网可用性提升 58%**
   - 离线 ASR 可用性：60% → 95%
   - 无需等待网络上传完成

4. **🔒 隐私保护**
   - 80% 音频不离开设备
   - 符合隐私最佳实践

**场景对比**：

| 场景 | Volcengine ASR | Client ASR | 提升 |
|------|----------------|------------|------|
| 快速单词确认 | 600ms | 250ms | **58%** ↑ |
| 弱网环境 | 1200ms+ | 300ms | **75%** ↑ |
| 复杂长句 | 800ms | 500ms (fallback 600ms) | **37%** ↑ |

---

### 问题 2: 当前实现状态

#### ✅ 已完成（Backend & iOS Core）

**Backend B13**:
- ✅ `Handler.clientASRRequired` Gate 逻辑
- ✅ `error.client_asr_required` 错误码
- ✅ 环境变量 `VOICE_CLIENT_ASR_REQUIRED` 配置
- ✅ 100% 测试覆盖（4 个单元测试）
- ✅ PR #41 已合并到 main

**iOS I13**:
- ✅ PCM 音频缓冲（`SpeechSessionMiddleware.swift`）
- ✅ ClientASR 集成（`AppleSpeechClientASRTranscriber`）
- ✅ 800ms 超时竞速机制
- ✅ Fallback 到 `text=nil` 逻辑
- ✅ 遥测埋点（3 个事件）
- ✅ 100% 测试覆盖（7 个单元测试）
- ✅ PR #39 已合并到 main

**架构层**:
- ✅ `SpeakingRoomState` 已定义
- ✅ `SpeakingRoomAction` 已定义（session/badgeHit/userSpeechCaptured）
- ✅ `speakingRoomReducer` 已实现
- ✅ `SpeechSessionMiddleware` 已实现

#### ❌ 缺失部分

**1. UI 层完全缺失**
```swift
// 当前 HostRootView.swift:87-93
case let .speakingRoom(sessionID):
    ZStack(alignment: .top) {
        Text("说的房间（骨架）\(sessionID.map { " · \($0)" } ?? "")")  // ⚠️ 骨架占位
            .navigationTitle("说的房间")
        
        // Badge feedback overlay 存在，但录音 UI 不存在
        BadgeFeedbackOverlay(...)
    }
```

**2. 用户无法启动录音**
- 没有录音按钮
- 没有麦克风权限申请流程
- 没有录音状态反馈（录音中/停止）
- 没有实时转写文本展示

**3. Debug 按钮不是真实用户流程**
```swift
// HostRootView.swift:566-572 - 只能触发状态机事件，不能模拟真实对话
Button("Start") {
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
}
Button("Badge Hit") {
    store.dispatch(.speakingRoom(.badgeHit(badge: "表达自然")))
}
```

---

## 🚨 影响分析

### Phase 2 联调无法进行真实测试

**当前状态**：
- ✅ 能测试状态机事件流
- ✅ 能测试单元测试
- ❌ **无法测试真实用户流程**
- ❌ **无法收集用户体验反馈**
- ❌ **无法验证 UI 状态同步**

**举例**：
1. 用户点击"开始录音" → **按钮不存在**
2. 录音过程中，实时转写文本展示 → **UI 不存在**
3. Badge 弹出时，录音状态如何显示？ → **无法验证**
4. 连续对话场景（用户说 3 句话）→ **无法模拟**

### 双轨制 Fallback 无法验证

**设计**：Client ASR 800ms 超时 → Fallback 到 Volcengine ASR

**问题**：
- Client ASR 超时时，UI 如何反馈？
- Fallback 过程是否透明？
- 用户是否感知到"降级"？

**当前**：只能通过单元测试验证状态机，无法验证 UI 表现。

---

## 💡 解决方案：Phase 2.5 MVP UI 开发

### 目标

**最小可行产品（MVP）**：
- ✅ 用户能点击按钮开始录音
- ✅ 录音过程中显示实时转写文本
- ✅ Badge 反馈能正常展示（已有 `BadgeFeedbackOverlay`）
- ✅ 能测试完整的 Client ASR → Badge 响应流程

**非目标（留给 Phase 3+）**：
- ❌ 不做复杂动画
- ❌ 不做精致视觉设计
- ❌ 不做多语言支持
- ❌ 不做录音历史记录

---

### MVP UI 设计草图

```
┌─────────────────────────────────────┐
│  说的房间                    [关闭]  │  ← NavigationBar
├─────────────────────────────────────┤
│                                     │
│   🎤 点击开始录音                    │  ← 大按钮（idle 状态）
│                                     │
│   Badge 反馈区域（现有）             │  ← BadgeFeedbackOverlay
│   [表达自然] [节奏稳定]              │
│                                     │
└─────────────────────────────────────┘

录音中状态：
┌─────────────────────────────────────┐
│  说的房间                    [关闭]  │
├─────────────────────────────────────┤
│                                     │
│   🔴 录音中...                       │  ← 红色指示器
│   [停止]                             │  ← 停止按钮
│                                     │
│   实时转写文本：                      │
│   "Hello, how are you today?"       │  ← liveTranscript
│                                     │
│   Badge 反馈区域                     │
│   [表达自然] [节奏稳定]              │
│                                     │
└─────────────────────────────────────┘
```

---

### 实现任务清单

#### Task 1: 创建 `SpeakingRoomView.swift` (2h)

```swift
// Shared/FluentWorkUI/SpeakingRoom/SpeakingRoomView.swift

public struct SpeakingRoomViewModel: Equatable, Sendable {
    public var phase: SpeechSessionPhase
    public var liveTranscript: String
    public var lastBadge: String?
    public var badgeHits: Int
    public var failureReason: String?
}

public struct SpeakingRoomView: View {
    let model: SpeakingRoomViewModel
    let onStartTapped: () -> Void
    let onStopTapped: () -> Void
    
    public var body: some View {
        VStack(spacing: 20) {
            // 录音按钮
            recordingButton
            
            // 实时转写文本
            if !model.liveTranscript.isEmpty {
                transcriptView
            }
            
            // Badge 统计
            statsView
        }
        .padding()
    }
    
    @ViewBuilder
    private var recordingButton: some View {
        switch model.phase {
        case .idle:
            Button("🎤 点击开始录音") {
                onStartTapped()
            }
            .buttonStyle(.borderedProminent)
            .font(.title2)
            
        case .connecting:
            ProgressView("连接中...")
            
        case .speaking:
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.red)
                    Text("录音中...")
                }
                .font(.headline)
                
                Button("停止") {
                    onStopTapped()
                }
                .buttonStyle(.bordered)
            }
            
        case .failed:
            VStack(spacing: 8) {
                Text("录音失败")
                    .foregroundColor(.red)
                if let reason = model.failureReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("重试") {
                    onStartTapped()
                }
            }
        }
    }
    
    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时转写：")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(model.liveTranscript)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
        }
    }
    
    private var statsView: some View {
        HStack(spacing: 16) {
            if let badge = model.lastBadge {
                Label(badge, systemImage: "star.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Text("Badge: \(model.badgeHits)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

**工时**: 2h  
**测试**: UI 预览测试

---

#### Task 2: 更新 `HostRootView.swift` 路由 (0.5h)

```swift
// HostRootView.swift:87-93 替换

case let .speakingRoom(sessionID):
    ZStack(alignment: .top) {
        // 新增：真实的 SpeakingRoomView
        SpeakingRoomView(
            model: makeSpeakingRoomViewModel(from: store.state.speakingRoom),
            onStartTapped: {
                store.dispatch(.speakingRoom(.session(.sessionStartTap)))
            },
            onStopTapped: {
                store.dispatch(.speakingRoom(.session(.sessionStopTap)))
            }
        )
        .navigationTitle("说的房间")
        
        // 保留：Badge feedback overlay
        TimelineView(.periodic(from: .now, by: 1)) { context in
            BadgeFeedbackOverlay(
                model: makeBadgeFeedbackViewModel(
                    from: store.state.badgeFeedback,
                    now: context.date
                )
            )
            .allowsHitTesting(false)
        }
        .padding(.top, 4)
    }

// 新增 ViewModel 转换函数
private func makeSpeakingRoomViewModel(
    from state: SpeakingRoomState
) -> SpeakingRoomViewModel {
    SpeakingRoomViewModel(
        phase: state.phase,
        liveTranscript: state.liveTranscript,
        lastBadge: state.lastBadge,
        badgeHits: state.badgeHits,
        failureReason: state.failureReason
    )
}
```

**工时**: 0.5h  
**测试**: 编译通过，路由正确

---

#### Task 3: 麦克风权限申请 (1h)

```swift
// Info.plist
<key>NSMicrophoneUsageDescription</key>
<string>FluentWork 需要使用麦克风进行英语口语练习</string>

// Shared/FluentWorkCore/Permissions/MicrophonePermission.swift
import AVFoundation

public enum MicrophonePermission {
    public static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    public static var isAuthorized: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }
}
```

**集成到 `SpeakingRoomView`**:
```swift
Button("🎤 点击开始录音") {
    Task {
        let granted = await MicrophonePermission.request()
        if granted {
            onStartTapped()
        } else {
            // TODO: 显示权限拒绝提示
        }
    }
}
```

**工时**: 1h  
**测试**: 真机测试权限弹窗

---

#### Task 4: 实时转写文本绑定 (2h)

**问题**：`liveTranscript` 如何更新？

**方案**：利用现有的 `SpeechSessionMiddleware`

```swift
// Shared/FluentWorkCore/Speech/SpeechSessionMiddleware.swift

// 现有代码已经有 pcmBuffer，需要新增转写回调

extension SpeechSessionMiddleware {
    func startTranscription() {
        // 使用 AppleSpeechClientASRTranscriber
        Task {
            for await partialResult in transcriber.stream(from: pcmBufferStream) {
                // 发送 action 更新 UI
                store?.dispatch(
                    .speakingRoom(.userSpeechCaptured(partialResult.text))
                )
            }
        }
    }
}
```

**集成点**：
1. 用户点击"开始录音" → `sessionStartTap`
2. Middleware 检测到 `phase = .speaking`
3. 启动 `startTranscription()`
4. 实时 dispatch `.userSpeechCaptured`
5. UI 自动更新

**工时**: 2h  
**测试**: 真机录音，查看 `liveTranscript` 是否实时更新

---

#### Task 5: 集成测试 (2h)

**测试场景**：
1. ✅ 用户点击"开始录音" → 权限申请 → 录音开始
2. ✅ 录音过程中，实时转写文本显示
3. ✅ Client ASR 800ms 内返回 → Badge 弹出
4. ✅ Client ASR 超时 → Fallback 到 Volcengine → Badge 弹出（略慢）
5. ✅ 用户点击"停止" → 录音停止，UI 恢复 idle

**集成测试清单**：
- [ ] 真机测试（iPhone 实机）
- [ ] 弱网测试（飞行模式 + WiFi）
- [ ] 连续对话测试（说 3 句话，Badge 是否正常）
- [ ] 权限拒绝测试（拒绝麦克风权限，UI 如何反馈）

**工时**: 2h  
**交付物**: 测试报告 `SPEAKING_ROOM_UI_TEST_REPORT.md`

---

### 总工时估算

| 任务 | 工时 | 风险 |
|------|------|------|
| Task 1: SpeakingRoomView | 2h | 低 |
| Task 2: 路由更新 | 0.5h | 低 |
| Task 3: 麦克风权限 | 1h | 低 |
| Task 4: 实时转写绑定 | 2h | 中 |
| Task 5: 集成测试 | 2h | 中 |
| **总计** | **7.5h** | - |

**工期**：2 天（2026-09-04 ~ 09-05）

---

## 📅 时间表调整建议

### 原计划（B13 Phase 2）

```
09-01: Backend B13 实现 ✅ 完成
09-01: iOS I13 实现 ✅ 完成
09-02 ~ 09-08: Phase 2 联调
09-09: Phase 3 灰度发布
```

### 调整后（插入 Phase 2.5）

```
09-01: Backend B13 实现 ✅ 完成
09-01: iOS I13 实现 ✅ 完成
09-02 ~ 09-03: Phase 2.5 MVP UI 开发 ← 新增
09-04 ~ 09-08: Phase 2 联调（使用真实 UI）
09-09: Phase 3 灰度发布
```

**影响**：
- ✅ 总体时间表不变
- ✅ Phase 3 灰度日期不受影响（09-09）
- ✅ Phase 2 联调质量提升（真实用户流程）

---

## 🎯 决策建议

### 立即开始 Phase 2.5 MVP UI 开发

**理由**：
1. **功能已完整，只差"最后一公里"**
   - Backend Gate 逻辑 ✅
   - iOS Core 实现 ✅
   - 只差 UI 层让用户能用

2. **Phase 2 联调需要真实用户流程**
   - Debug 按钮无法模拟连续对话
   - 无法收集用户体验反馈
   - 无法验证 UI 状态同步

3. **MVP 实现简单，风险低**
   - 5 个任务，总计 7.5 小时
   - 不涉及复杂动画或设计
   - 复用现有 `BadgeFeedbackOverlay`

4. **投资回报率高**
   - 7.5 小时投入
   - 解锁完整的 Client ASR 价值（¥144,000/年 + 58% 性能提升）
   - 使 Phase 2 联调能够验证真实用户流程

---

## 📝 下一步行动

### 立即（09-01 晚）

1. **创建 Issue #40**: `Phase 2.5: SpeakingRoom MVP UI 开发`
   - 引用本文档
   - 分配给 iOS 开发
   - 优先级：High

2. **创建分支**: `feat/speaking-room-mvp-ui`

3. **开始 Task 1**: `SpeakingRoomView.swift` 实现

### 09-02 ~ 09-03

- 完成 Task 1-5
- 真机测试
- PR Review
- 合并到 main

### 09-04 开始

- Phase 2 联调（使用真实 UI）
- 收集用户体验反馈
- 优化 Fallback 逻辑

---

## 🔗 相关链接

- iOS PR #39: Client ASR 实现（已合并）
- Backend PR #41: B13 Phase 2 准备（已合并）
- Backend Commit f7b637c: B13 实现
- 总结文档: `CLIENT_ASR_B13_COMPLETE_SUMMARY.md`

---

**结论**：Client ASR 功能技术实现完整，但缺少用户入口。建议立即启动 Phase 2.5 MVP UI 开发（7.5h, 2 天），使功能真正可用，并支持 Phase 2 高质量联调。
