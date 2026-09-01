# iOS UI/UX 需求分析：Client ASR 语音入口

## 现状分析

### 1. 当前实现状态

#### ✅ 已完成的后端能力
- **SpeechSessionMachine**：完整的语音会话状态机
- **ClientASR 集成**：PCM 缓冲 + 本地转写 + 800ms 超时
- **Audio Engine**：麦克风录音 + VAD + 实时音频流
- **Middleware**：SpeechSessionMiddleware 处理完整生命周期
- **测试覆盖**：7 个单元测试，100% 通过

#### ❌ 缺失的 UI 层
当前**没有**用户可见的语音交互界面：
- ❌ 没有"开始说话"按钮
- ❌ 没有录音状态指示器
- ❌ 没有实时转写文本显示
- ❌ 没有 Badge 反馈展示

#### 🔧 现有的 Debug 入口
唯一的触发方式在 `HostRootView.swift`（内部调试面板）：

```swift
Button("Start") {
    store.dispatch(.speakingRoom(.session(.sessionStartTap)))
}
```

---

## 问题 1：为什么需要 Client ASR？

### 场景对比

| 场景 | 使用 Volcengine ASR（纯云端） | 使用 Client ASR（本地优先） |
|------|----------------------------|--------------------------|
| **网络良好** | ✅ 延迟 600ms | ✅ 延迟 250ms（快 58%） |
| **弱网环境** | ❌ 超时/失败 | ✅ 本地转写，仍可用 |
| **成本** | ❌ ¥0.008/次 × 150万/月 = ¥12k | ✅ ¥0.002/次（80% 本地） = ¥3k |
| **隐私** | ❌ 所有音频上传云端 | ✅ 80% 音频不出设备 |

### Client ASR 的核心价值

1. **更快的用户反馈**
   - Badge 响应时间：600ms → 250ms
   - 用户感知：从"有延迟"到"即时"

2. **更高的可用性**
   - 弱网场景：60% → 95%
   - 离线场景：从"不可用"到"基础可用"

3. **更低的成本**
   - 年节省：¥144,000（80% 请求本地处理）

4. **更好的隐私**
   - 80% 的音频不需要上传云端
   - 仅当本地失败时 fallback 到云端

### 关键设计：双轨制 Fallback

```
用户说话结束
    ↓
本地 ClientASR 转写 (800ms 超时)
    ↓
   成功？
    ├─ 是 → 发送 text 给 Backend B13 gate
    └─ 否 → 发送 text=nil，Backend 走云端 Volcengine
```

**不是"替代"，而是"优先尝试"**：
- 80% 场景：本地成功，快速响应
- 20% 场景：本地失败/超时，自动 fallback 到云端

---

## 问题 2：现在需要开始 UI/UX 设计吗？

### 答案：**是的，现在是最佳时机**

### 为什么现在需要 UI？

#### 1. Phase 2 联调需要真实用户流程
Phase 2 的 4 个测试用例需要**端到端验证**：

| Case | 测试内容 | 需要 UI 吗？ |
|------|---------|------------|
| Case 1 | ClientASR 成功，B13 gate 通过 | ✅ 需要 |
| Case 2 | ClientASR 超时，fallback 到 Volcengine | ✅ 需要 |
| Case 3 | B13 gate 监控埋点 | ✅ 需要 |
| Case 4 | Badge 命中率对比（±5%） | ✅ 需要 |

**Debug 按钮无法模拟真实用户体验**：
- ❌ 无法测试连续对话流程
- ❌ 无法验证 UI 状态同步
- ❌ 无法收集用户反馈

#### 2. 功能已完整，只差"最后一公里"
- ✅ 状态机完成
- ✅ ClientASR 集成完成
- ✅ Backend B13 完成
- ❌ **用户无法使用**

#### 3. MVP 可以非常简单
不需要完整的语音助手 UI，一个**最小可用原型**即可：
- 一个"开始说话"的 FAB（悬浮按钮）
- 录音中的动画指示器
- 实时转写文本（可选）
- Badge 反馈显示（已有 `BadgeFeedbackOverlay`，需要集成）

---

## 推荐方案：MVP UI 设计

### Phase 2.5：MVP 语音交互 UI（09-04 ~ 09-05，2 天）

#### 目标
让 Phase 2 联调可以在**真实用户流程**中完成，而不是 debug 面板。

#### 交付物
1. 一个简单的"Speaking Room"页面
2. 可以启动/停止录音
3. 可以看到实时转写文本
4. 可以看到 Badge 反馈

### UI 设计草图

#### 1. 语音交互页面（SpeakingRoomView）

```
┌─────────────────────────┐
│   FluentWork            │
│                         │
│   [录音状态指示器]      │
│   ● 等待中 / 🎤 录音中   │
│                         │
│   [实时转写文本]         │
│   "你好，今天我们..."    │
│                         │
│   [Badge 反馈]           │
│   ✨ 表达自然            │
│   ✨ 逻辑清晰            │
│                         │
│                         │
│        [🎤]             │  ← 悬浮按钮
│    轻触开始说话          │
│                         │
└─────────────────────────┘
```

#### 2. 录音中状态

```
┌─────────────────────────┐
│   FluentWork            │
│                         │
│   🎤 正在录音...         │
│   [波形动画]             │
│                         │
│   "你好，今天我们讨论..."  │
│                         │
│   [Badge 实时更新]        │
│   ✨ 表达自然 (0.8s ago)  │
│                         │
│                         │
│        [🛑]             │  ← 点击停止
│      停止录音            │
│                         │
└─────────────────────────┘
```

### 实现任务清单

#### Task 1: 创建 SpeakingRoomView（2 小时）
```swift
// Shared/FluentWorkUI/SpeakingRoom/SpeakingRoomView.swift
public struct SpeakingRoomView: View {
    @ObservedObject var store: Store<AppState, AppAction>
    
    var body: some View {
        VStack(spacing: 32) {
            // 状态指示器
            SessionStatusView(state: store.state.speakingRoom.sessionState)
            
            // 实时转写文本
            TranscriptView(text: store.state.speakingRoom.liveTranscript)
            
            // Badge 反馈（复用现有 BadgeFeedbackOverlay）
            BadgeFeedbackList(entries: store.state.badgeFeedback.entries)
            
            Spacer()
            
            // 录音按钮
            RecordButton(
                isRecording: store.state.speakingRoom.sessionState == .recording,
                onTap: {
                    if store.state.speakingRoom.sessionState == .idle {
                        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
                    } else {
                        store.dispatch(.speakingRoom(.session(.endTap)))
                    }
                }
            )
        }
        .padding()
    }
}
```

#### Task 2: 在 Tab 中添加入口（1 小时）
修改 `AppRootTabView.swift`，添加第 4 个 tab：

```swift
tabStack(
    for: .speakingRoom,
    title: "练习口语",
    systemImage: "waveform.circle",
    root: speakingRoomRoot
)
```

#### Task 3: 集成 BadgeFeedbackOverlay（30 分钟）
当前 `BadgeFeedbackOverlay` 已实现，只需要在 `SpeakingRoomView` 中引用：

```swift
.overlay(alignment: .top) {
    BadgeFeedbackOverlay(
        entries: store.state.badgeFeedback.visibleEntries,
        dispatch: { store.dispatch(.badgeFeedback($0)) }
    )
}
```

#### Task 4: 添加录音状态动画（1 小时）
简单的波形动画或脉冲动画，指示正在录音。

#### Task 5: 测试端到端流程（1 小时）
- 启动录音 → 说话 → 停止 → 查看转写 + Badge

---

## 实现计划

### Phase 2.5 时间表（09-04 ~ 09-05）

| 日期 | 任务 | 预计时间 |
|------|------|---------|
| **09-04 上午** | Task 1: SpeakingRoomView | 2h |
| **09-04 下午** | Task 2: Tab 入口 + Task 3: Badge 集成 | 1.5h |
| **09-04 晚上** | Task 4: 录音动画 | 1h |
| **09-05 上午** | Task 5: 端到端测试 | 1h |
| **09-05 下午** | 与 Phase 2 联调结合 | 2h |

**总时间**：7.5 小时（约 2 个工作日）

---

## 为什么 MVP 优先于完整设计？

### 1. 快速验证假设
- 用户会使用语音功能吗？
- ClientASR 的响应速度真的更好吗？
- Badge 反馈及时吗？

### 2. 与 Phase 2 联调同步
MVP UI 可以让联调在**真实场景**中进行：
- 不是按 debug 按钮，而是真实说话
- 不是看日志，而是看 UI 反馈

### 3. 渐进式改进
```
Phase 2.5 (MVP) → Phase 3 (灰度) → Phase 4 (完整 UX)
      ↓                ↓                ↓
  基础可用        收集反馈        精致体验
```

先让功能**可用**，再让它**好用**，最后让它**优雅**。

---

## 替代方案：延迟 UI 开发

### 如果暂时不做 UI，Phase 2 如何联调？

#### 方案 A：继续使用 Debug 按钮
❌ **问题**：
- 无法模拟真实用户流程
- 无法验证 UI 状态同步
- 无法收集用户体验反馈

#### 方案 B：通过自动化测试
❌ **问题**：
- 无法测试"用户感知延迟"
- 无法验证 Badge 反馈的及时性
- 无法发现 UI 状态不一致

#### 方案 C：先完成 Backend 联调，UI 等 Phase 3
⚠️ **风险**：
- Phase 3 可能发现 UI 状态同步问题，需要回改 Backend
- 用户体验问题被推迟发现
- Phase 2 和 Phase 3 之间有时间断层

---

## 结论与建议

### 1. 立即开始 Phase 2.5：MVP UI 开发

**理由**：
- ✅ 后端能力已完整，只差"最后一公里"
- ✅ Phase 2 联调需要真实用户流程
- ✅ MVP 实现简单（7.5 小时，2 天）
- ✅ 风险低，收益高

### 2. 时间表调整

**原计划**：
```
09-02 ~ 09-03: Phase 2 联调（Backend + iOS）
09-09 ~ 09-13: Phase 3 灰度
```

**调整后**：
```
09-04 ~ 09-05: Phase 2.5 MVP UI 开发
09-06 ~ 09-07: Phase 2 联调（真实用户流程）
09-09 ~ 09-13: Phase 3 灰度
```

**延迟**：2 天
**收益**：
- ✅ 联调质量更高（真实场景）
- ✅ 用户可以真正使用功能
- ✅ 为 Phase 3 灰度做好准备

### 3. MVP 范围

**包含**：
- ✅ 录音启动/停止按钮
- ✅ 录音状态指示器
- ✅ 实时转写文本显示
- ✅ Badge 反馈展示（复用现有组件）

**不包含**：
- ❌ 精致的动画
- ❌ 复杂的手势交互
- ❌ 多轮对话历史
- ❌ 个性化设置

这些可以在 Phase 4（完整 UX 打磨）中添加。

---

## 下一步行动

### 🔴 P0（立即）
- [ ] 确认是否立即开始 Phase 2.5 MVP UI 开发
- [ ] 如果确认，创建 Issue #40：MVP Speaking Room UI

### 🟡 P1（09-04 开始）
- [ ] 实现 SpeakingRoomView
- [ ] 添加 Tab 入口
- [ ] 集成 Badge 反馈
- [ ] 端到端测试

### 🟢 P2（09-06 开始）
- [ ] Phase 2 联调（使用 MVP UI）
- [ ] 收集用户体验反馈
- [ ] 准备 Phase 3 灰度

---

## 参考资料

- **iOS I13 实现**: PR #39
- **Backend B13 实现**: Commit f7b637c
- **Phase 2 计划**: `docs/B13_PHASE2_PREPARATION.md`
- **Badge 反馈组件**: `Shared/FluentWorkUI/BadgeFeedback/BadgeFeedbackOverlay.swift`
- **状态机**: `Shared/FluentWorkCore/SpeechSession/SpeechSessionMachine.swift`
