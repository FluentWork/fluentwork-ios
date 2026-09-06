# Skill I15 — TTS 播放集成(P0, W3 Day 3, B17 CLOSED 后)

> **Master**: 待建 GitHub Issue `I15: 说的房间 TTS 播放集成`
> **Sub-tickets**: 5 (T-I15-1..5)
> **总工时**: 1.0 dev-day
> **阻塞**: B17(TTS Provider CLOSED)
> **关联**: I17(复用 TTSPlayer), D-2 音色表

---

## §0 Master Issue Body

**Title**: `I15: 说的房间 TTS 播放集成`
**Labels**: `ios`, `v2.0`, `priority: P0`, `tts`, `audio`
**Milestone**: `V2.0 W3`

```markdown
## 🎯 目标
iOS 端 TTS 音频流接收 + 播放 + 用户打断:
- 收到 voicegateway WSS 推送的 Opus 帧 → 立即解码播放
- 用户按住 HoldToSpeakButton → 中断 AI 播放 + 立刻进入 listening 状态
- 流式首字 P90 ≤ 400ms

## 🚧 阻塞条件
- B17(TTS Provider backend)CLOSED——voicegateway 已支持流式 Opus TTS 推送

## 📐 Sub-tickets

| # | Ticket | 工时 |
|---|---|---|
| T-I15-1 | TTSPlayer + Opus 解码 | 0.3d |
| T-I15-2 | WSS 帧分发增强 | 0.2d |
| T-I15-3 | 打断兼容 + 状态机联动 | 0.2d |
| T-I15-4 | 音色选择 UI + UserDefaults | 0.2d |
| T-I15-5 | 性能测试 + Snapshot | 0.1d |

## 🔗 关联
- 启动包:fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md
- 架构:fluentwork-meta/docs/30_技术方案/32_FluentWork-iOS App端技术设计文档.md §六
- 决策:fluentwork-meta/docs/40_研发流程与协作/47_D1_D5_开放技术决策备忘录_2026-09-03.md §D-2
- I17 复用:TTSPlayer(共享 Opus 解码器)
```

---

## §1 T-I15-1 — TTSPlayer + Opus 解码

**Labels**: `ios`, `v2.0`, `priority: P0`, `tts`, `audio`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
新建 `TTSPlayer`,支持 Opus 流式解码 + AVAudioEngine 播放。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Audio/TTSPlayer.swift`:
   ```swift
   public final class TTSPlayer {
       private let audioEngine = AVAudioEngine()
       private let playerNode = AVAudioPlayerNode()
       private var decoder: OpusDecoder?
       private let queue = DispatchQueue(label: "ttsplayer", qos: .userInteractive)
       
       public init() throws {
           try setupAudioSession()
           try setupEngine()
           decoder = OpusDecoder()
       }
       
       public func enqueueOpusFrame(_ opusData: Data) {
           queue.async { [weak self] in
               guard let pcm = self?.decoder?.decode(opusData) else { return }
               self?.scheduleBuffer(pcm)
           }
       }
       
       public func interrupt() {
           queue.async { [weak self] in
               self?.playerNode.stop()
           }
       }
       
       private func scheduleBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
           playerNode.scheduleBuffer(pcmBuffer, at: nil, options: .interrupts) {
               // 播放完成回调
           }
           if !playerNode.isPlaying {
               playerNode.play()
           }
       }
   }
   ```
2. OpusDecoder 使用系统 libopus 或第三方库(如 iOS 不内置)
3. `AppDependencies` 注入 TTSPlayer 单例

## ✅ 验收
- [ ] T-I15-1 收到首帧 Opus →出声 P90 ≤ 400ms
- [ ] 流式多帧连续播放无卡顿、无重复
- [ ] 编译通过,iPhone 6s+ 支持

## 🔗 依赖
- Blocked by: B17 CLOSED
- Blocks: T-I15-2, I17 复用
- Master: I15
```

---

## §2 T-I15-2 — WSS 帧分发增强

**Labels**: `ios`, `v2.0`, `priority: P0`, `tts`, `networking`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
`WSFrameDispatcher` 新增 ai.tts.* 帧处理,转发给 TTSPlayer。

## 📋 实施步骤
1. 在 `SpeakingRoomTransportBridge` 或现有 WSS 处理层添加:
   ```swift
   case let frame as AITTSStartFrame:
       ttsPlayer.interrupt()  // 清空旧 buffer
       currentTTSSessionID = frame.sessionID
       log("tts.start", sessionID: currentSessionID)
   
   case let frame as AITTSAudioFrame:
       ttsPlayer.enqueueOpusFrame(frame.opusData)
   
   case let frame as AITTSEndFrame:
       log("tts.end", sessionID: currentTTSSessionID)
       // 不立即停止,等播放器自然排空
   ```
2. 新建 `AITTSStartFrame`/`AITTSAudioFrame`/`AITTSEndFrame` Codable structs
3. 帧格式对齐 backend voicegateway WSS 协议(参考 38_ §六)

## ✅ 验收
- [ ] ai.tts.start/audio/end 帧正确处理
- [ ] 帧乱序容忍(无崩溃)
- [ ] 日志埋点正确

## 🔗 依赖
- Blocked by: T-I15-1
- Blocks: T-I15-3
- Master: I15
```

---

## §3 T-I15-3 — 打断兼容 + 状态机联动

**Labels**: `ios`, `v2.0`, `priority: P0`, `tts`, `state`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
用户按住 HoldToSpeakButton 时中断 TTS,状态机从 speaking 切到 listening。

## 📋 实施步骤
1. 修改 `SpeechSessionMachine` 的用户打断逻辑:
   ```swift
   func handleUserInterrupt() {
       ttsPlayer.interrupt()  // 立即停止 TTS
       state = .listening
       startRecording()
       Task {
           try? await webSocketClient.send(frame: ClientAudioStartFrame(
               sessionID: currentSessionID,
               turnID: currentTurnID
           ))
       }
   }
   ```
2. `SpeakingRoomFeature` 在 speaking 状态检测 HoldToSpeakButton 的 onStart 事件
3. I21 T-I21-3 已处理 speaking→listening 状态转换,本 ticket 补充 TTS 中断调用

## ✅ 验收
- [ ] T-I15-3 用户按住打断 → AI 静音 P99 ≤ 100ms
- [ ] 打断后用户说话正常,无音频残留
- [ ] T-I15-4 打断后 TTS 恢复正常工作

## 🔗 依赖
- Blocked by: T-I15-2, I21 T-I21-2(isValidTransition speaking→listening)
- Blocks: T-I15-5
- Master: I15
```

---

## §4 T-I15-4 — 音色选择 UI + UserDefaults

**Labels**: `ios`, `v2.0`, `priority: P0`, `tts`, `ui`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
Setting 入口实现 4 个 D-2 音色选择 UI,持久化到 UserDefaults。

## 📋 实施步骤
1. 新建 `Shared/FluentWorkCore/Settings/VoiceSettingsView.swift`:
   ```swift
   struct VoiceSettingsView: View {
       @AppStorage("selected_voice_id") private var selectedVoiceID = "zh_male_tech_01"
       private let voices = [
           ("zh_male_tech_01", "技术男声", "适合技术场景"),
           ("en_female_professional", "专业女声", "适合商务场景"),
           ("en_male_narrator", "叙述男声", "适合讲故事"),
           ("en_female_clear", "清晰女声", "适合日常对话")
       ]
       var body: some View {
           List {
               ForEach(voices, id: \.0) { voice in
                   Button {
                       selectedVoiceID = voice.0
                   } label: {
                       HStack {
                           VStack(alignment: .leading) {
                               Text(voice.1).font(.headline)
                               Text(voice.2).font(.caption).foregroundStyle(.secondary)
                           }
                           Spacer()
                           if selectedVoiceID == voice.0 {
                               Image(systemName: "checkmark")
                           }
                       }
                   }
                   .foregroundStyle(.primary)
               }
           }
           .navigationTitle("选择音色")
       }
   }
   ```
2. `VoiceSettingsView` 挂到 Setting 导航路径
3. 创建 session 时读取 UserDefaults 的 `voice_id` 并传给 backend(B17 端)

## ✅ 验收
- [ ] T-I15-8 音色切换 UI 正常显示
- [ ] 切换后下次启动保留(持久化)
- [ ] 4 个音色选项完整

## 🔗 依赖
- Blocked by: 无(独立 UI)
- Blocks: T-I15-5
- Master: I15
```

---

## §5 T-I15-5 — 性能测试 + Snapshot + 兼容性

**Labels**: `ios`, `v2.0`, `priority: P0`, `tts`, `observability`, `testing`
**Milestone**: `V2.0 W3`

### Body

```markdown
## 🎯 目标
性能测试 + Snapshot + 蓝牙/后台/VoiceOver 兼容性。

## 📋 实施步骤
1. 新建 `Tests/FluentWorkCoreTests/TTSPlayerTests.swift`:
   - testEnqueueOpusFrame_DecodesAndPlays
   - testInterrupt_StopsImmediately
   - testMultipleFrames_NoAudioGlitch
2. 新建 `Tests/FluentWorkCoreTests/VoiceSettingsViewTests.swift` Snapshot
3. 兼容性处理:
   - 后台切换:`AVAudioSession.interruptionNotification` 触发 pause
   - 蓝牙断开:`AVAudioSession.routeChangeNotification` 切换扬声器
   - VoiceOver:TTS 播放状态改变时触发 `UIAccessibility.announcement`

## ✅ 验收
- [ ] T-I15-1 首字 P90 ≤ 400ms(性能测试)
- [ ] T-I15-5 网络抖动容忍
- [ ] T-I15-6 后台自动暂停
- [ ] T-I15-9 蓝牙耳机断开切换扬声器
- [ ] T-I15-10 VoiceOver 提示

## 🔗 依赖
- Blocked by: T-I15-3, T-I15-4
- Blocks: 无(Master 收口)
- Master: I15
```

---

## §5 I15 — 阻塞与对应

- **Blocked by**: [FluentWork/fluentwork-backend#44 (B17 TTS Provider)](https://github.com/FluentWork/fluentwork-backend/issues/44) 状态为 CLOSED
- 跨仓对应文件:`fluentwork-backend/.scratch/issues/2026-09-06-W3-backend-tickets/03-skill-B17-TTS-Provider.md`(含 #52-#56 5 个 backend sub-ticket)
- 跨仓评审表:`fluentwork-backend/.scratch/issues/2026-09-06-W3-backend-tickets/跨仓对应表.md`

## §6 执行顺序与总工时

```
B17 CLOSED 后:
T-I15-1 (0.3d) ──▶ T-I15-2 (0.2d) ──▶ T-I15-3 (0.2d) ──┬──▶ T-I15-5 (0.1d)
                                                        │
T-I15-4 (0.2d, 独立) ──────────────────────────────────┘
```

**总工时**:1.0 dev-day
**推荐 Owner**:iOS 工程师 B
**关键路径**:B17 CLOSED 是唯一阻塞;I17 复用 TTSPlayer
