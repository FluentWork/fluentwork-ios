# FluentWork Practice Room 架构设计

**日期**: 2026-09-21  
**目标**: 设计 FluentWork "说的房间"核心功能的完整架构，支持素材驱动的实时语音对话、即时反馈、卡壳救援

---

## 文档导航

本系列文档从资深 iOS 架构专家视角，为 FluentWork 的核心功能"说的房间"（Practice Room）设计完整的技术架构。

### 设计原则

1. **对准实时口语**: 首响延迟 P90 ≤ 1.5s 是生死线
2. **素材驱动**: 用户真实工作素材贯穿对话、评价、炼化全流程
3. **可扩展性**: 支持迷你会话（3-5轮）到标准会话（8-12轮），未来扩展到多场景
4. **核心功能稳定**: 实时对话、即时反馈、卡壳救援是护城河，必须工程级稳定
5. **个性化基础**: 语料库、话术块、间隔重复是数据飞轮，架构必须支持

### 核心功能识别（按优先级）

根据 PRD 分析，核心功能点为：

**P0 - 生死线功能**:
1. **实时语音对话** (B1-B5): WebSocket duplex、流式 ASR/LLM/TTS、首响 ≤1.5s
2. **即时反馈系统** (B7): 实时检测话术块命中、轻量徽章、不打断对话流
3. **卡壳救援机制** (B8): 3秒触发、三层梯子、TTS 语音给提示
4. **素材驱动对话** (A1-A3, B2): 素材提炼、场景生成、AI 扮演角色
5. **转录与回顾** (B5, C1-C3): 完整转录、三层评价、双栏对照
6. **话术块炼化** (D1-D2): 自动提炼、三元组结构、状态管理

**P1 - 体验增强**:
7. **迷你会话支持** (B1): 3-5轮、约2分钟、计入北极星指标
8. **音频重播** (B4): AI 消息音频重播、展开文本
9. **实时转录浮层** (B3): 延迟 ≤1s
10. **语料库基础** (F1-F2): 存储、检索、状态追踪

### 技术挑战

1. **延迟优化**: 首响 1.5s、转录 1s、评价 15s
2. **并发安全**: 实时检测并行于对话流、不阻塞 TTS
3. **状态管理**: Session/Turn 双层状态机 + 话术块状态追踪
4. **资源控制**: 音频流、WebSocket、后台任务生命周期管理
5. **错误恢复**: 网络抖动、ASR 失败、卡壳救援超时

### 文档结构

| 文档 | 内容 | 优先级 |
|------|------|--------|
| [README.md](README.md) | 本文档 - 总览与导航 | - |
| [01_requirements_analysis.md](01_requirements_analysis.md) | 需求分析与功能拆解 | P0 |
| [02_system_architecture.md](02_system_architecture.md) | 系统架构与模块设计 | P0 |
| [03_realtime_dialogue_design.md](03_realtime_dialogue_design.md) | 实时对话引擎设计 | P0 |
| [04_instant_feedback_system.md](04_instant_feedback_system.md) | 即时反馈系统设计 | P0 |
| [05_stall_rescue_mechanism.md](05_stall_rescue_mechanism.md) | 卡壳救援机制设计 | P0 |
| [06_material_driven_engine.md](06_material_driven_engine.md) | 素材驱动引擎设计 | P0 |
| [07_phrase_block_system.md](07_phrase_block_system.md) | 话术块系统设计 | P0 |
| [08_state_management.md](08_state_management.md) | 状态管理与生命周期 | P0 |
| [09_performance_optimization.md](09_performance_optimization.md) | 性能优化策略 | P1 |
| [10_testing_strategy.md](10_testing_strategy.md) | 测试策略与质量保证 | P1 |
| [11_implementation_roadmap.md](11_implementation_roadmap.md) | 实施路线图 | P1 |

### 与现有架构的关系

本系列基于已完成的 **TTS WebSocket 架构设计** (docs/70_tts_wss_refactor/)：

- **复用**: WebSocket 协议、Actor 并发模型、音频链路、错误处理
- **扩展**: 增加素材管理、话术块系统、即时反馈、卡壳救援
- **集成**: Practice Room 作为业务层，使用 TTS WebSocket 作为基础设施层

### 设计哲学

**核心假设**（来自 PRD §三）:
- 口语产出是实时过程，必须在数百毫秒内完成
- 组块化（chunk）是语言产出的基本单位
- 主动召回训练 > 识别性知识
- 素材相关性决定动机和留存
- 即时强化的时效性决定习得效率

**工程转化**:
1. 延迟预算: 每个模块都有明确的延迟上限
2. 无锁设计: 音频线程、实时检测并行不阻塞
3. 结构性防御: 非法状态不可表达、卡壳必有救援
4. 可观测性: 全链路埋点、延迟监控、命中率追踪
5. 降级策略: 每个 P0 功能都有降级方案

### 成功标准

**技术指标**:
- 首响延迟 P90 ≤ 1.5s
- 转录延迟 ≤ 1s
- 评价生成 ≤ 15s
- 命中检测延迟 ≤ 500ms（不阻塞 TTS）
- 卡壳救援触发 ≤ 3s

**业务指标**:
- 首次开口率（进入房间 → 说出第一句话）
- 周完整流水线完成率（含迷你会话）
- 话术块命中率（B7 验证）
- 卡壳救援触发率与有效率

---

## 快速开始

### 阅读路径

**快速了解** (30分钟):
1. 本 README
2. [需求分析](01_requirements_analysis.md) - 理解核心需求
3. [系统架构](02_system_architecture.md) - 把握整体设计
4. [实施路线图](11_implementation_roadmap.md) - 了解开发计划

**技术深入** (2-3小时):
5. [实时对话引擎](03_realtime_dialogue_design.md)
6. [即时反馈系统](04_instant_feedback_system.md)
7. [卡壳救援机制](05_stall_rescue_mechanism.md)
8. [素材驱动引擎](06_material_driven_engine.md)
9. [话术块系统](07_phrase_block_system.md)

**实施准备** (1天):
10. [状态管理](08_state_management.md)
11. [性能优化](09_performance_optimization.md)
12. [测试策略](10_testing_strategy.md)
13. 完整阅读所有文档

### 关键决策点

**Week 1-2: GO/NO-GO 决策**
- 首响延迟必须达到 P90 ≤ 1.5s
- 如果无法达标，启动降级方案并重估排期
- 这是全局前置风险阀门

**MVP 核心**:
- 说（实战演练）+ 即时反馈 + 卡壳救援
- 读（回顾评价）+ 炼化（话术块提取）
- 基础语料库（状态管理）

**后续增强** (V1.1+):
- 发音评测（V1.1）
- 闪测调度引擎（层级2/3训练）
- 话题建议系统
- 团队协作功能

---

## 架构原则

### 1. 延迟是产品生死线

首响延迟直接决定对话感。每个模块都有明确的延迟预算：

```
用户说话结束
  ↓ ≤200ms
ASR 识别完成
  ↓ ≤800ms
LLM 首 token
  ↓ ≤300ms
TTS 首音频块
  ↓ ≤200ms
音频播放开始
= 1.5s (P90)
```

### 2. 并发安全优先

所有核心服务使用 Actor 模型：
- 编译时并发安全
- 消息传递通信
- 避免数据竞争
- 清晰的隔离边界

### 3. 护城河在数据飞轮

产品的壁垒不在 AI 对话能力（可被复制），而在：
- 用户个人语料库的累积效应
- 话术块的状态追踪与调度
- 实战使用数据的闭环反馈
- 个性化素材的深度内化

架构设计必须服务于数据飞轮的构建。

### 4. 渐进式增强

MVP 专注核心体验：
- 标准会话（8-12轮）+ 迷你会话（3-5轮）
- Daily Standup 预置场景
- 基础话术块管理
- 简化间隔重复

后续版本逐步增强：
- 更多场景模板
- 高级调度算法
- 发音评测
- 团队功能

### 5. 可观测性内置

从第一天起就内置：
- 全链路延迟埋点
- 关键指标监控
- 错误率追踪
- 用户行为分析

不是事后补充，而是架构的一部分。

---

## 技术栈

### 客户端
- **语言**: Swift 5.9+
- **框架**: SwiftUI、Swift Concurrency (Actor)
- **最低版本**: iOS 17+
- **音频**: AVFoundation、AVAudioSession
- **网络**: URLSession WebSocket、Combine
- **持久化**: SwiftData、FileManager
- **测试**: XCTest、Swift Testing

### 基础设施复用
- **TTS WebSocket 架构**: docs/70_tts_wss_refactor/
- **Actor 并发模型**: 已验证的并发安全模式
- **音频链路管理**: AVAudioSession 生命周期
- **错误处理**: 分层错误处理机制

### 后端依赖
- **素材提炼**: POST /api/materials/extract
- **场景生成**: POST /api/sessions/generate-scenario
- **WebSocket 对话**: wss://api/sessions/{id}/dialogue
- **话术块匹配**: POST /api/phrase-blocks/match
- **卡壳救援**: POST /api/rescue/generate-ladder
- **回顾生成**: POST /api/sessions/{id}/review
- **话术块炼化**: POST /api/sessions/{id}/distill

---

## 风险与对策

### 高风险

**1. 首响延迟超标**
- **风险**: 无法达到 1.5s，对话感崩塌
- **对策**: Week 1-2 压测前置，超标启动降级方案
- **降级**: 分段 TTS、预连接、缓存优化

**2. 即时反馈误命中**
- **风险**: 用户说错话却被正强化
- **对策**: 阈值保守化（≥0.85）、语义判定、上线前必测

**3. 卡壳救援依赖**
- **风险**: 用户等梯子不主动尝试
- **对策**: 3秒阈值、逐层升级、救援率监控

### 中风险

**4. 素材引用率不达标**
- **风险**: AI 对话偏离素材，≥60% 引用率不达标
- **对策**: Prompt 强制注入、话轮检测、引用率埋点

**5. 并发竞态条件**
- **风险**: 实时检测、卡壳救援、转录并行导致状态不一致
- **对策**: Actor 隔离、消息传递、状态机防护

**6. 资源泄漏**
- **风险**: WebSocket、音频会话、录音文件未释放
- **对策**: 生命周期管理、自动清理、内存监控

---

## 下一步

1. **阅读完整文档**: 按推荐路径阅读所有11个技术文档
2. **团队 Kick-off**: 分配模块责任、确定接口契约
3. **Week 1-2 压测**: 验证首响延迟（GO/NO-GO 决策点）
4. **迭代开发**: 按 8 周路线图推进

---

**最后更新**: 2026-09-21  
**维护者**: iOS 架构团队  
**上游真相源**: fluentwork-meta/docs/20_产品设计/20_FluentWork产品需求文档PRD.md
