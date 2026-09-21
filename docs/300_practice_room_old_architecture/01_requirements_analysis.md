# 需求分析与功能拆解

**日期**: 2026-09-21  
**文档**: Practice Room Architecture - Part 1  
**状态**: 设计阶段

---

## 一、PRD 核心需求映射

### 1.1 产品定位与设计原则

**一句话定位**（PRD §三）:
> 把你的工作日常变成英语练习——以真实工作场景为料、以口语演练为核心的个性化职场英语训练引擎。

**设计原则优先级**:
1. **对准实时口语**: 下次开会能脱口而出
2. **用户素材驱动**: 真实工作素材生成练习内容
3. **自输出镜像**: 让用户"看见"自己说的英文
4. **干预分层**: 对话流内只有卡壳救援，纠错后置到回顾
5. **延迟即体验**: 首响延迟是生死线
6. **练为实战服务**: 最终出口是与真人沟通

### 1.2 核心机制

**流水线**（PRD §5.1）:
```
说（实战演练）
  ↓
读（自我输出镜像）
  ↓
炼化（话术块萃取）
  ↓
提取训练（内化）
  ↓
语料库（资产沉淀）
  ↓
话题建议（走向真人实战）
```

**话术块机制**（PRD §5.2）:
- 核心数据单元: **场景意图（中文）+ 英文话术块 + 对比锚点（用户原始说法）**
- 必须从用户真实卡壳点提炼
- 闭环追踪: AI 实时检测用户是否用上已训练的话术块
- 用上 → 即时轻量正反馈
- 未用 → 下次提取训练加重调度

**卡壳救援机制**（PRD §5.4）:
- 设计原则 4 在对话流内的唯一实现
- 触发: 用户沉默 ≥3 秒，或说出未完成句
- 三层递梯子（逐层升级不跳层）:
  1. 句首骨架: "I think the main risk is…"
  2. 中文意图提示: "先说结论，再说原因"
  3. 完整表达: 只在 1、2 都无效时给
- 三条硬约束:
  1. 不追问
  2. 不离开语音流（走 TTS）
  3. 不记入失败（卡壳点进入炼化候选）

**北极星指标**:
- 周完成"说 → 回顾 → 入库"完整流水线至少 1 次的用户占比
- **口径含迷你会话**（3-5 回合、约 2 分钟）

---

## 二、功能需求拆解

### 2.1 模块 B: 说（Practice Room 核心）

| 功能 ID | 优先级 | 需求描述 | 技术关键点 | 验收标准 |
|---------|--------|----------|------------|----------|
| **B1** | P0 | 实时语音对话 | WebSocket duplex、流式 ASR/LLM/TTS | 首响 P90 ≤ 1.5s；支持标准会话（8-12轮）与迷你会话（3-5轮） |
| **B2** | P0 | 素材驱动对话 | Prompt 注入素材提炼 + 场景目标 | ≥60% AI 话轮引用素材内容 |
| **B3** | P0 | 实时转录浮层 | ASR 流式结果展示 | 延迟 ≤ 1s |
| **B4** | P1 | AI 消息重播 | 音频缓存、文本展开 | 可重播任意 AI 消息 |
| **B5** | P0 | 转录数据产出 | 完整转录（区分说话人）+ 异步分析 | 转录 3 秒内可查看 |
| **B6** | P1 | 中途放弃 | 会话终止、清理资源 | 不进回顾、不入库 |
| **B7** | P0 | 即时反馈 | 实时检测命中话术块、轻量徽章 | 不阻塞语音流；命中延迟 ≤ 500ms；阈值保守化（宁可漏报不可错报） |
| **B8** | P0 | 卡壳救援 | 沉默检测、三层梯子、TTS 提示 | 触发 ≤ 3s；不追问、不离开语音流、不记入失败 |

### 2.2 模块 A: 素材输入

| 功能 ID | 优先级 | 需求描述 | 技术关键点 | 验收标准 |
|---------|--------|----------|------------|----------|
| **A1** | P0 | 文本粘贴生成练习 | 文本解析（≤2000字）、AI 提炼 | 5秒内展示；有预期 loading |
| **A2** | P0 | 一句话描述场景 | AI 补全场景设定 | ≥10字即可开始；≤1秒不阻塞 |
| **A3** | P0 | 预置场景 | Daily Standup 预置卡 | 一键进入 |
| **A5** | P0 | 演示素材体验 | 预置演示素材 | 首次用户主路径 |

### 2.3 模块 C: 读（回顾）

| 功能 ID | 优先级 | 需求描述 | 技术关键点 | 验收标准 |
|---------|--------|----------|------------|----------|
| **C1** | P0 | 转录展示 | 按话轮、用户话轮可回听 | 完整展示对话历史 |
| **C2** | P0 | 三层评价 | 目标达成度、问题清单、提高建议 | 每条引用原句；≤15s 生成 |
| **C3** | P0 | 双栏对照 | 基于意图还原的改写、差异高亮 | 3-8条对照 |

### 2.4 模块 D: 话术块炼化

| 功能 ID | 优先级 | 需求描述 | 技术关键点 | 验收标准 |
|---------|--------|----------|------------|----------|
| **D1** | P0 | 自动提炼话术块 | 三元组结构、优先卡壳点 | 3-5个话术块 |
| **D2** | P0 | 编辑与入库 | 卡片交互、批量入库 | 可编辑/丢弃/入库 |

---

## 三、核心功能点识别

### 3.1 护城河功能（P0 - 生死线）

基于 PRD §14.3 "终极护城河：FluentWork 不是豆包"，以下功能构成不可复制的壁垒：

**1. 实时语音对话系统** (B1)
- **为什么是护城河**: 首响延迟决定对话感，是产品生死线
- **核心挑战**: WebSocket duplex、流式处理、延迟优化
- **技术要点**: 
  - ASR → LLM → TTS 三级流式链路
  - 首响 P90 ≤ 1.5s
  - 支持标准会话（8-12轮）与迷你会话（3-5轮）
- **工程量**: 约 2 周（含压测验证）

**2. 即时反馈系统** (B7)
- **为什么是护城河**: 实时强化的时效性决定习得效率（PRD §2.2 第一性原理）
- **核心挑战**: 实时检测并行于对话流、不阻塞 TTS、误命中防御
- **技术要点**:
  - 异步并行检测话术块命中
  - 轻量徽章 + AI 自然确认
  - 阈值保守化（宁可漏报不可错报）
  - 命中延迟 ≤ 500ms
- **工程量**: 约 1 周

**3. 卡壳救援机制** (B8)
- **为什么是护城河**: 设计原则 4"干预分层"在对话流内的唯一实现，决定首次开口率（漏斗首环）
- **核心挑战**: 沉默检测、三层梯子递增、TTS 融入对话流
- **技术要点**:
  - 沉默 ≥3s 或未完成句检测
  - 三层梯子（句首骨架 → 中文提示 → 完整表达）
  - 不追问、不离开语音流、不记入失败
  - 触发 ≤ 3s
- **工程量**: 约 1 周

**4. 素材驱动引擎** (A1-A3, B2)
- **为什么是护城河**: 个人工作素材内化是与通用产品的分水岭（PRD §14.3 维度三）
- **核心挑战**: 素材提炼、场景生成、AI 引用素材对话
- **技术要点**:
  - 文本解析与提炼（≤2000字）
  - Prompt 注入素材 + 场景目标
  - ≥60% AI 话轮引用素材
- **工程量**: 约 1 周

**5. 话术块系统** (D1-D2, F1-F2)
- **为什么是护城河**: 结构化的个人资产沉淀，构成数据飞轮（PRD §14.3 维度二）
- **核心挑战**: 三元组提炼、状态追踪、调度引擎
- **技术要点**:
  - 三元组: 场景意图 + 英文块 + 对比锚点
  - 状态管理: 新入库 → 训练中 → 已自动化
  - 实战使用次数追踪
- **工程量**: 约 1 周

**6. 回顾与评价系统** (C1-C3)
- **为什么是护城河**: 结构化镜像反馈，让用户"看见"差距（PRD §14.3 维度四）
- **核心挑战**: 三层评价、双栏对照、意图还原
- **技术要点**:
  - 三层评价卡（目标达成度、问题清单、提高建议）
  - 双栏对照（基于意图还原，非 ASR 原文）
  - 评价生成 ≤ 15s
- **工程量**: 约 1 周

### 3.2 体验增强功能（P1）

**7. 迷你会话支持** (B1)
- 3-5轮、约2分钟
- 计入北极星指标（周完整流水线完成率）
- 服务"碎片时间多、整块时间少"的用户画像

**8. 音频重播与展开** (B4)
- AI 消息音频重播
- 文本展开
- 提升对话可懂度

**9. 实时转录浮层** (B3)
- 延迟 ≤ 1s
- 确认自己说了什么

**10. 中途放弃** (B6)
- 会话终止
- 不进回顾、不入库

---

## 四、技术需求分析

### 4.1 性能需求

| 指标 | 目标 | 关键路径 |
|------|------|----------|
| 对话首响 P90 | ≤ 1.5s | WebSocket 连接 + ASR 启动 + LLM 首 token + TTS 首音频块 |
| 转录浮层延迟 | ≤ 1s | ASR 流式结果 → UI 更新 |
| 评价生成时长 | ≤ 15s | 转录 → AI 分析 → 三层评价 + 双栏对照 |
| 命中检测延迟 | ≤ 500ms | 用户话轮 → 语义匹配 → 徽章展示（不阻塞 TTS） |
| 卡壳救援触发 | ≤ 3s | 沉默检测 → 梯子生成 → TTS 播放 |
| 炼化生成 | ≤ 10s | 转录 → AI 提炼 → 3-5 个话术块 |

**延迟预算分解**（首响 1.5s）:
```
用户说话结束
  ↓ ≤200ms    (VAD 检测 + 音频缓冲)
ASR 识别完成
  ↓ ≤800ms    (LLM 处理 + 首 token 生成)
LLM 首 token
  ↓ ≤300ms    (TTS 合成首音频块)
TTS 首音频块
  ↓ ≤200ms    (网络传输 + 音频播放启动)
音频播放开始
= 1.5s (P90)
```

### 4.2 并发与状态管理需求

**并发场景**:
1. **对话流**（主线程）: 用户说话 → ASR → LLM → TTS → 音频播放
2. **即时反馈检测**（并行）: 用户话轮 → 语义匹配话术块 → 徽章展示
3. **卡壳救援监控**（并行）: 沉默计时 → 触发判断 → 梯子生成
4. **实时转录**（并行）: ASR 流式结果 → UI 浮层更新
5. **音频录制**（后台）: 用户音频 → 本地缓存 → 回顾页回听

**状态机需求**:
- **Session 状态**: Idle → Preparing → Active → Paused → Completed → Abandoned
- **Turn 状态**: Listening → Processing → Speaking → Completed
- **救援状态**: Monitoring → Layer1 → Layer2 → Layer3 → Resolved
- **话术块状态**: New → Training → Automated

**并发安全策略**:
- 使用 Swift Actor 模型确保编译时并发安全
- 音频线程与 UI 线程隔离
- 无锁设计，通过消息传递通信
- 状态机防护非法状态转换

### 4.3 数据模型需求

**核心实体**:

```swift
// Practice Session
struct PracticeSession: Identifiable, Codable {
    let id: UUID
    let userID: String
    let materialID: UUID?
    let scenarioType: ScenarioType
    let sessionType: SessionType
    var status: SessionStatus
    var turns: [Turn]
    let startTime: Date
    var endTime: Date?
    var metadata: SessionMetadata
}

enum ScenarioType: String, Codable {
    case dailyStandup
    case designReview
    case custom
    case demo
}

enum SessionType: String, Codable {
    case standard  // 8-12轮
    case mini      // 3-5轮
}

enum SessionStatus: String, Codable {
    case preparing
    case active
    case paused
    case completed
    case abandoned
}

// Turn (话轮)
struct Turn: Identifiable, Codable {
    let id: UUID
    let speaker: Speaker
    let audioURL: URL?
    let transcript: String
    let timestamp: Date
    let asrConfidence: Float?
    var matchedPhraseBlocks: [UUID]  // 命中的话术块 ID
    var pronunciationScore: Float?   // V1.1
    let duration: TimeInterval
}

enum Speaker: String, Codable {
    case user
    case ai
}

// Phrase Block (话术块)
struct PhraseBlock: Identifiable, Codable {
    let id: UUID
    let userID: String
    let scenarioIntent: String       // 中文场景意图
    let englishPhrase: String        // 英文话术块
    let contrastAnchor: String       // 用户原始说法
    var sceneTags: [String]
    var functionTags: [String]
    var status: PhraseBlockStatus
    var nextScheduleTime: Date?
    var realWorldUsageCount: Int     // 实战使用次数
    var successCount: Int
    var failureCount: Int
    let createdAt: Date
    var updatedAt: Date
}

enum PhraseBlockStatus: String, Codable {
    case new
    case training
    case automated
}

// Material (素材)
struct Material: Identifiable, Codable {
    let id: UUID
    let userID: String
    let content: String              // ≤2000 字
    let sourceType: MaterialSourceType
    var extractedTopics: [String]
    var extractedTerms: [String]
    var discussionPoints: [String]
    let createdAt: Date
}

enum MaterialSourceType: String, Codable {
    case textPaste
    case oneLineDescription
    case preset
    case demo
}

// Review (回顾)
struct Review: Identifiable, Codable {
    let id: UUID
    let sessionID: UUID
    let goalAchievement: GoalAchievement
    let issueList: [Issue]
    let improvementSuggestions: [String]  // ≤3条
    let contrastPairs: [ContrastPair]     // 3-8条
    let generatedAt: Date
}

struct GoalAchievement: Codable {
    let score: Int  // 0-100
    let summary: String
}

struct Issue: Identifiable, Codable {
    let id: UUID
    let category: IssueCategory
    let originalText: String
    let explanation: String
    let lineNumber: Int?
}

enum IssueCategory: String, Codable {
    case grammar
    case fluency
    case informationGap
}

// Contrast Pair (双栏对照)
struct ContrastPair: Identifiable, Codable {
    let id: UUID
    let userUtterance: String
    let improvedVersion: String
    let intentBased: Bool
    let differences: [DifferenceHighlight]
}

struct DifferenceHighlight: Codable {
    let range: Range<String.Index>
    let type: DifferenceType
}

enum DifferenceType: String, Codable {
    case wordChoice
    case structure
    case grammar
}
```

### 4.4 集成需求

**后端 API 契约**:

```swift
protocol PracticeRoomAPIService {
    // 素材提炼
    func extractMaterial(content: String) async throws -> ExtractedMaterial
    
    // 场景生成
    func generateScenario(
        material: Material,
        sceneType: ScenarioType
    ) async throws -> ScenarioSetup
    
    // WebSocket 对话（全双工）
    func connectDialogueSession(
        sessionID: String,
        config: DialogueConfig
    ) async throws -> AsyncStream<DialogueEvent>
    
    // 话术块命中检测
    func matchPhraseBlocks(
        userText: String,
        phraseBlocks: [PhraseBlock]
    ) async throws -> [PhraseMatch]
    
    // 卡壳救援
    func generateRescueLadder(
        context: RescueContext,
        level: RescueLevel
    ) async throws -> RescueLadder
    
    // 回顾生成
    func generateReview(
        sessionID: String,
        transcript: [Turn],
        material: Material
    ) async throws -> Review
    
    // 话术块炼化
    func distillPhraseBlocks(
        sessionID: String,
        transcript: [Turn]
    ) async throws -> [PhraseBlock]
}

struct ExtractedMaterial: Codable {
    let topics: [String]
    let keyTerms: [String]
    let discussionPoints: [String]
    let suggestedScenario: ScenarioType
    let suggestedAIRole: String
}

struct ScenarioSetup: Codable {
    let scenario: String
    let userRole: String
    let aiRole: String
    let objective: String
    let aiSystemPrompt: String
}

struct DialogueConfig: Codable {
    let sessionID: String
    let systemPrompt: String
    let userContext: [String: String]
    let enableInstantFeedback: Bool
    let enableStallRescue: Bool
}

enum DialogueEvent {
    case connected
    case aiAudioChunk(Data)
    case aiTextDelta(String)
    case userTranscriptUpdate(String)
    case turnCompleted(Turn)
    case phraseMatched(PhraseMatch)
    case stallDetected
    case rescueLadderProvided(RescueLadder)
    case error(Error)
    case disconnected
}

struct PhraseMatch: Codable {
    let phraseBlockID: UUID
    let userText: String
    let confidence: Double
    let semanticEquivalence: Bool
}

struct RescueContext: Codable {
    let sessionID: String
    let recentTurns: [Turn]
    let currentSilenceDuration: TimeInterval
    let dialogueContext: String
}

enum RescueLevel: Int, Codable {
    case skeleton = 1
    case intentHint = 2
    case fullExpression = 3
}

struct RescueLadder: Codable {
    let level: RescueLevel
    let text: String
    let ttsAudio: Data?
}
```

**现有基础设施复用** (docs/70_tts_wss_refactor/):
- WebSocket 协议层: URLSession WebSocket
- Actor 并发模型: Swift Concurrency
- 音频链路管理: AVAudioSession、AVAudioPlayer
- 错误处理机制: 分层错误、重试策略

### 4.5 非功能需求

**可靠性**:
- 核心链路可用性 ≥ 99.5%
- AI 故障降级为文本对话模式
- 网络抖动自动重连（≤3次，指数退避）
- 本地缓存支持离线查看语料库

**可观测性**:
- 全链路延迟埋点（首响、转录、评价、命中、救援）
- ASR 置信度监控
- 命中率与误命中率追踪
- 救援触发率与有效率监控
- 性能指标实时上报

**资源控制**:
- AVAudioSession 正确申请与释放
- 来电、切后台自动暂停可恢复
- WebSocket 生命周期管理
- 音频缓存清理策略（按时间、大小）
- 内存占用监控与告警

**隐私合规**:
- 素材与录音仅用于生成练习
- 加密存储（AES-256）、TLS 传输
- 一键删除全部数据（级联删除）
- 不用于训练 AI 模型
- 符合 GDPR、CCPA 要求

**安全**:
- Token 刷新机制
- API 请求签名
- 防重放攻击
- 敏感数据不记录日志

---

## 五、关键技术挑战

### 5.1 延迟优化

**挑战**: 首响 P90 ≤ 1.5s 是生死线，超标对话感崩塌

**策略**:
1. **预连接**: 进入房间前预建 WebSocket 连接
2. **流式处理**: ASR/LLM/TTS 全流式，不等完整结果
3. **并行优化**: 命中检测并行于 TTS，不阻塞主流
4. **降级方案**: 延迟超限降级为分段 TTS
5. **缓存预热**: 常用场景 Prompt 预加载
6. **边缘优化**: VAD 前置、音频预压缩

**监控**:
- P50/P90/P99 延迟分位数
- 按地域、网络类型分层统计
- 超时率告警（> 5%）

### 5.2 并发安全

**挑战**: 实时检测、转录浮层、卡壳救援并行于对话流，可能导致数据竞争

**策略**:
1. **Actor 隔离**: 每个子系统独立 Actor，消息传递通信
2. **无锁设计**: 音频线程不持锁
3. **状态机防护**: 非法状态不可表达（用枚举而非布尔标志）
4. **错误隔离**: 子系统故障不影响主流（用 Result 类型）
5. **测试覆盖**: Thread Sanitizer、并发压测

**关键点**:
- `@MainActor` 标记 UI 更新逻辑
- Actor 方法用 `async` 确保串行执行
- 避免跨 Actor 共享可变状态
- 使用 `AsyncStream` 传递事件

### 5.3 即时反馈的误命中防御

**挑战**: 用户说了错的话却被正强化（PRD §十二 风险）

**策略**:
1. **阈值保守化**: 只有高置信命中（≥0.85）才出徽章
2. **语义判定**: 基于语义等价而非字面匹配
3. **双重验证**: embedding 粗筛 + LLM 精筛
4. **误命中率监控**: 上线前必测，持续追踪（目标 < 5%）
5. **降级开关**: 远程关闭即时反馈功能
6. **用户申诉**: 记录申诉数据，持续优化

**实现细节**:
```swift
// 保守阈值
let matchConfidenceThreshold: Double = 0.85

// 双重验证
func checkMatch(userText: String, phraseBlock: PhraseBlock) async -> Match? {
    // 第一层：embedding 相似度
    let similarity = await computeEmbeddingSimilarity(userText, phraseBlock.englishPhrase)
    guard similarity >= matchConfidenceThreshold else { return nil }
    
    // 第二层：LLM 语义等价判定
    let isEquivalent = await llmSemanticEquivalence(userText, phraseBlock.englishPhrase)
    guard isEquivalent else { return nil }
    
    return Match(phraseBlockID: phraseBlock.id, confidence: similarity)
}
```

### 5.4 卡壳救援的依赖风险

**挑战**: 梯子给得太早，用户会等梯子而不是先尝试（PRD §十二 风险）

**策略**:
1. **3秒阈值**: 给用户足够思考时间
2. **逐层升级**: 不跳层，先给轻量提示
3. **救援率监控**: 救援率过高（> 30%）→ 调整场景难度
4. **不记入失败**: 救援过的话术块照常进入炼化
5. **A/B 测试**: 测试不同阈值的效果

**监控指标**:
- 救援触发率: 触发次数 / 总话轮数
- 救援有效率: 用户继续说话 / 触发次数
- 救援层级分布: Layer 1/2/3 的比例

### 5.5 素材引用率保障

**挑战**: AI 对话必须 ≥60% 引用素材内容（B2 验收标准）

**策略**:
1. **Prompt 强制注入**: 素材提炼结果作为 System Prompt
2. **话轮检测**: 每轮 AI 回复检测素材引用
3. **引用率埋点**: 实时监控，低于阈值告警
4. **素材重激活**: 连续未引用时 AI 主动提及素材
5. **温度调节**: 降低 LLM temperature 提高贴题率

**实现**:
```swift
// 话轮引用检测
func detectMaterialReference(aiResponse: String, material: ProcessedMaterial) -> Bool {
    let keywords = material.extractedTopics + material.keyTerms
    return keywords.contains { aiResponse.localizedCaseInsensitiveContains($0) }
}

// 引用率计算
var materialReferenceRate: Double {
    let referencedTurns = turns.filter { turn in
        turn.speaker == .ai && detectMaterialReference(turn.transcript, material)
    }
    return Double(referencedTurns.count) / Double(turns.filter { $0.speaker == .ai }.count)
}
```

---

## 六、架构设计约束

### 6.1 来自 PRD 的硬约束

1. **首响延迟**: P90 ≤ 1.5s（生死线）
2. **转录延迟**: ≤ 1s
3. **评价生成**: ≤ 15s
4. **命中检测**: 不阻塞 TTS（≤ 500ms）
5. **卡壳救援**: 触发 ≤ 3s，不离开语音流
6. **素材引用**: ≥60% AI 话轮引用素材
7. **迷你会话**: 支持 3-5 轮、约 2 分钟
8. **北极星指标**: 周完成"说 → 回顾 → 入库"≥1 次（含迷你会话）

### 6.2 来自现有架构的约束

1. **iOS 17+**: SwiftUI + Swift Concurrency
2. **WebSocket 协议**: 复用已有 TTS WebSocket 架构
3. **Actor 模型**: 并发安全基于 Actor
4. **音频链路**: AVAudioSession 管理
5. **本地缓存**: 语料库、练习历史离线可访问

### 6.3 可扩展性要求

1. **场景扩展**: 当前 Daily Standup，未来扩展到 Design Review、1:1 等
2. **话术块调度**: 当前简化间隔重复，未来扩展到层级 2/3
3. **发音评测**: V1.1 接入，架构预留接口
4. **多模型路由**: 小模型优先、大模型兜底，成本可控
5. **团队功能**: V2.0 团队协作，数据模型需支持多用户

---

## 七、成功标准

### 7.1 技术指标

| 指标 | 目标 | 监控方式 | P0/P1 |
|------|------|----------|-------|
| 首响延迟 P90 | ≤ 1.5s | 全链路埋点 | P0 |
| 转录延迟 | ≤ 1s | ASR 结果时间戳 | P0 |
| 评价生成时长 | ≤ 15s | 异步任务耗时 | P0 |
| 命中检测延迟 | ≤ 500ms | 检测任务时间戳 | P0 |
| 卡壳救援触发 | ≤ 3s | 沉默检测到梯子播放 | P0 |
| 素材引用率 | ≥ 60% | AI 话轮分析 | P0 |
| 核心链路可用性 | ≥ 99.5% | 错误率监控 | P0 |
| 误命中率 | < 5% | 人工标注验证 | P0 |

### 7.2 业务指标

| 指标 | 说明 | 北极星关联 | P0/P1 |
|------|------|------------|-------|
| 首次开口率 | 进入房间 → 说出第一句话 | 漏斗首环 | P0 |
| 周完整流水线完成率 | 周完成"说 → 回顾 → 入库"≥1 次（含迷你会话） | 北极星指标 | P0 |
| 话术块命中率 | 已入库话术块在对话中被用上的比例 | 验证即时反馈有效性 | P0 |
| 卡壳救援触发率 | 有效救援占总对话的比例 | 验证救援机制覆盖 | P0 |
| 卡壳救援有效率 | 救援后用户继续说话的比例 | 验证梯子设计合理性 | P0 |
| 迷你会话完成率 | 迷你会话占总会话的比例 | 验证碎片时间场景 | P1 |

### 7.3 质量标准

1. **稳定性**: 核心功能无 P0 Bug
2. **可测试性**: 单元测试覆盖率 ≥ 70%，关键路径 ≥ 90%
3. **可观测性**: 全链路埋点，关键指标可视化
4. **可维护性**: 模块解耦，依赖注入，文档完整
5. **性能**: 内存占用 < 200MB，电量消耗正常

---

## 八、风险评估

### 8.1 高风险（需要 Week 1-2 验证）

| 风险 | 影响 | 概率 | 缓解策略 | GO/NO-GO |
|------|------|------|----------|----------|
| 首响延迟超标 | 产品生死线 | 中 | 压测前置、降级方案 | YES |
| 网络不稳定导致断线 | 用户体验崩塌 | 高 | 自动重连、本地缓存 | YES |
| 并发竞态条件 | 数据不一致 | 中 | Actor 隔离、充分测试 | NO |

### 8.2 中风险

| 风险 | 影响 | 概率 | 缓解策略 |
|------|------|------|----------|
| 即时反馈误命中 | 错误正强化 | 中 | 阈值保守化、上线前必测 |
| 卡壳救援依赖 | 用户等梯子 | 低 | 3秒阈值、救援率监控 |
| 素材引用率不达标 | AI 偏离主题 | 中 | Prompt 强制注入、引用率埋点 |

### 8.3 低风险

| 风险 | 影响 | 概率 | 缓解策略 |
|------|------|------|----------|
| 资源泄漏 | 内存/电量 | 低 | 生命周期管理、自动清理 |
| 音频质量问题 | 可懂度下降 | 低 | 降噪、音量归一化 |

---

## 九、下一步

基于本需求分析，后续文档将展开：

1. **系统架构设计** (02): 模块划分、依赖关系、技术选型
2. **实时对话引擎** (03): WebSocket 链路、流式处理、延迟优化
3. **即时反馈系统** (04): 语义匹配、并行检测、误命中防御
4. **卡壳救援机制** (05): 沉默检测、三层梯子、TTS 融入
5. **素材驱动引擎** (06): 素材提炼、场景生成、Prompt 注入
6. **话术块系统** (07): 三元组管理、状态追踪、调度引擎
7. **状态管理** (08): Session/Turn 状态机、生命周期管理
8. **性能优化** (09): 延迟预算、并发优化、降级策略
9. **测试策略** (10): 单元测试、集成测试、性能测试
10. **实施路线图** (11): 里程碑、依赖关系、风险管理

---

**设计哲学回顾**（PRD §三）:

> 口语产出是实时过程，从"想表达"到"说出声音"必须在数百毫秒内完成。产品的护城河不在 AI 对话能力（可被复制），而在**用户语料库的累积效应**——练得越久，内容越贴个人，迁移成本越高。

架构设计的每一个决策，都要回答：**这个设计如何服务于"让用户在真实工作场景中脱口而出"这个终极目标？**

---

**最后更新**: 2026-09-21  
**下一文档**: [02_system_architecture.md](02_system_architecture.md)
