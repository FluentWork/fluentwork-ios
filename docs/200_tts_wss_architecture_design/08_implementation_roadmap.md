# 实施路线图

**日期**: 2026-09-21  
**目标**: 定义从设计到上线的完整实施计划，分阶段交付可验证的里程碑

---

## 一、实施策略

### 1.1 总体原则

- **增量交付**: 每个阶段产出可运行、可测试的系统
- **风险前置**: 优先解决最大的技术风险
- **快速验证**: 尽早在真机上验证核心假设
- **持续集成**: 每个阶段都保持代码可编译、可测试

### 1.2 阶段划分

```
Phase 0: 基础设施准备（1 周）
    ↓
Phase 1: 核心框架搭建（2 周）
    ↓
Phase 2: WebSocket 通信（1 周）
    ↓
Phase 3: 音频链路实现（2 周）
    ↓
Phase 4: UI 与集成（1 周）
    ↓
Phase 5: 优化与测试（2 周）
    ↓
Phase 6: Beta 发布与迭代（持续）
```

**总工期**: 约 9 周（基础版本）

---

## 二、Phase 0: 基础设施准备

**时间**: Week 1  
**目标**: 搭建开发环境、依赖管理、测试框架

### 2.1 任务清单

- [ ] **创建 Xcode 项目**
  - 使用 Swift Package Manager (SPM)
  - 支持 iOS 15.0+
  - 配置 `.gitignore`

- [ ] **集成第三方依赖**
  - Opus 编解码库（libopus）
  - Swift Atomics（无锁数据结构）
  - Logging 库

- [ ] **配置 CI/CD**
  - GitHub Actions / Xcode Cloud
  - 自动化测试
  - 代码覆盖率报告

- [ ] **设置测试框架**
  - XCTest 单元测试
  - XCUITest UI 测试
  - 测试工具类（Mock, Stub）

- [ ] **文档系统**
  - Swift-DocC
  - API 文档生成

### 2.2 项目结构

```
FluentWorkVoice/
├── App/
│   ├── FluentWorkVoiceApp.swift
│   └── ContentView.swift
├── Modules/
│   ├── Domain/
│   │   ├── VoiceSessionService.swift
│   │   ├── SessionState.swift
│   │   └── TurnState.swift
│   ├── Infrastructure/
│   │   ├── WebSocket/
│   │   │   ├── WebSocketTransport.swift
│   │   │   └── URLSessionWebSocketTransport.swift
│   │   ├── Audio/
│   │   │   ├── AudioEngine.swift
│   │   │   ├── OpusCodec.swift
│   │   │   └── AudioCaptureProcessor.swift
│   │   └── Protocols/
│   │       └── MessageProtocol.swift
│   └── Presentation/
│       ├── ViewModels/
│       │   └── ConversationViewModel.swift
│       └── Views/
│           └── ConversationView.swift
├── Tests/
│   ├── DomainTests/
│   ├── InfrastructureTests/
│   └── PresentationTests/
└── Package.swift
```

### 2.3 验收标准

- ✅ 项目可编译运行
- ✅ CI 流水线通过
- ✅ 至少有一个测试通过
- ✅ 依赖库成功集成

---

## 三、Phase 1: 核心框架搭建

**时间**: Week 2-3  
**目标**: 实现协议定义、状态机、Actor 框架

### 3.1 任务清单

**Week 2: 协议与数据模型**

- [ ] **定义 WebSocket 消息协议**
  - `WebSocketMessage` 结构体
  - `MessageType` 枚举
  - 所有 Data 类型（SessionStartData, AudioData 等）
  - JSON 编解码测试

- [ ] **定义状态机**
  - `SessionState` 枚举
  - `TurnState` 枚举
  - `SessionStateManager` actor
  - `TurnStateManager` actor
  - 状态转换测试（100% 覆盖）

- [ ] **错误体系**
  - `VoiceSessionError` 枚举
  - 5 大类错误定义
  - 错误恢复策略

**Week 3: 核心 Actor 框架**

- [ ] **VoiceSessionService Actor**
  - 基本接口定义
  - 状态管理集成
  - 事件发布机制（AsyncStream）
  - Mock 实现用于测试

- [ ] **协议抽象**
  - `WebSocketTransport` 协议
  - `AudioEngine` 协议
  - `TTSProvider` 协议
  - Mock 实现

- [ ] **依赖注入容器**
  - `ServiceContainer` 实现
  - 依赖注册与解析
  - 测试环境配置

### 3.2 验收标准

- ✅ 所有协议定义完成
- ✅ 状态机测试通过（覆盖率 >90%）
- ✅ VoiceSessionService 可独立测试
- ✅ Mock 实现可用于集成测试

### 3.3 里程碑 M1: 核心框架

**交付物**:
- 完整的协议定义
- 可测试的状态机
- Actor 框架骨架
- 80+ 单元测试

**Demo**: 可以通过 Mock 模拟完整对话流程（无真实网络/音频）

---

## 四、Phase 2: WebSocket 通信

**时间**: Week 4  
**目标**: 实现 WebSocket 连接、消息收发、重连机制

### 4.1 任务清单

- [ ] **URLSessionWebSocketTransport 实现**
  - 连接建立与关闭
  - 消息发送（JSON 序列化）
  - 消息接收（JSON 反序列化）
  - 错误处理

- [ ] **连接管理**
  - 心跳机制（30s 间隔）
  - 自动重连（指数退避）
  - 连接状态监控
  - 网络变化响应

- [ ] **序列号管理**
  - `SequenceNumberManager` actor
  - `SequenceValidator` actor
  - 乱序检测与恢复

- [ ] **集成测试**
  - Mock WebSocket Server
  - 连接流程测试
  - 重连场景测试
  - 消息顺序测试

### 4.2 验收标准

- ✅ 可以连接到真实 Backend
- ✅ 心跳保活正常工作
- ✅ 自动重连成功率 >95%
- ✅ 消息乱序正确处理

### 4.3 里程碑 M2: WebSocket 通信

**交付物**:
- 完整的 WebSocket 传输层
- 连接管理器
- 序列号管理器
- 20+ 集成测试

**Demo**: 可以与 Backend 建立连接，收发文本消息（无音频）

---

## 五、Phase 3: 音频链路实现

**时间**: Week 5-6  
**目标**: 实现音频采集、编码、解码、播放

### 5.1 任务清单

**Week 5: 音频采集与编码**

- [ ] **集成 Opus 库**
  - 编译 libopus for iOS
  - 创建 Swift 封装
  - 编码测试（PCM → Opus）
  - 解码测试（Opus → PCM）

- [ ] **AudioCaptureProcessor Actor**
  - AVAudioEngine 配置
  - installTap 音频回调
  - 重采样（48kHz → 16kHz）
  - 格式转换（Float32 → Int16）
  - 分帧（20ms）

- [ ] **无锁环形缓冲区**
  - `LockFreeRingBuffer` 实现
  - 音频线程写入
  - Actor 线程读取
  - 并发测试

**Week 6: 音频解码与播放**

- [ ] **AudioPlaybackProcessor Actor**
  - Opus 解码
  - 序列号排序
  - 播放队列管理
  - AVAudioPlayerNode 调度

- [ ] **音频会话管理**
  - AVAudioSession 配置
  - 中断处理
  - 路由变化处理
  - 权限检查

- [ ] **音质优化**
  - AEC/AGC/降噪验证
  - 延迟测量
  - 音质测试

### 5.2 验收标准

- ✅ 可以录制 20ms 音频帧
- ✅ Opus 编解码往返测试通过
- ✅ 无锁缓冲区零数据竞争（TSan）
- ✅ 音频播放无爆音/卡顿
- ✅ 端到端延迟 < 200ms

### 5.3 里程碑 M3: 音频链路

**交付物**:
- 完整的音频采集链路
- 完整的音频播放链路
- Opus 编解码器
- 30+ 音频测试

**Demo**: 可以录音并通过 WebSocket 发送到 Backend，接收并播放 AI 语音

---

## 六、Phase 4: UI 与集成

**时间**: Week 7  
**目标**: 实现用户界面，完成端到端集成

### 6.1 任务清单

- [ ] **ConversationViewModel**
  - 状态绑定（@Published）
  - 事件订阅（AsyncStream）
  - 用户操作处理
  - 错误展示

- [ ] **ConversationView (SwiftUI)**
  - 对话列表
  - 录音按钮（按住说话）
  - 状态指示器
  - 错误提示

- [ ] **音频播放 UI**
  - 波形动画
  - 播放进度
  - 音量指示

- [ ] **端到端集成**
  - VoiceSessionService ↔ ViewModel ↔ View
  - 真机测试
  - 性能优化

### 6.2 验收标准

- ✅ UI 响应流畅（60 FPS）
- ✅ 按住说话功能正常
- ✅ 错误提示友好
- ✅ 真机运行无崩溃

### 6.3 里程碑 M4: MVP 完成

**交付物**:
- 完整的用户界面
- 端到端功能集成
- 真机测试报告

**Demo**: 可以在 iPhone 上进行完整的语音对话

---

## 七、Phase 5: 优化与测试

**时间**: Week 8-9  
**目标**: 性能优化、稳定性测试、Bug 修复

### 7.1 任务清单

**Week 8: 性能优化**

- [ ] **延迟优化**
  - 音频缓冲区调优
  - 网络优先级设置
  - 预加载策略
  - 目标: 端到端 < 1.5s

- [ ] **内存优化**
  - Instruments 分析
  - 内存泄漏检测
  - 缓冲区大小优化
  - 目标: 峰值 < 50MB

- [ ] **CPU 优化**
  - Time Profiler 分析
  - 热点函数优化
  - Actor 边界减少
  - 目标: 平均 < 15%

**Week 9: 稳定性测试**

- [ ] **压力测试**
  - 长时间运行（1 小时）
  - 快速连续对话
  - 网络抖动模拟
  - 内存警告模拟

- [ ] **兼容性测试**
  - iOS 15, 16, 17
  - iPhone SE, 14, 15 Pro
  - 蓝牙耳机
  - AirPods

- [ ] **边缘场景测试**
  - 来电打断
  - 后台切换
  - 低电量模式
  - 弱网环境

### 7.2 验收标准

- ✅ 崩溃率 < 0.1%
- ✅ 首帧延迟 < 300ms
- ✅ 端到端延迟 < 1.5s
- ✅ 内存占用 < 50MB
- ✅ 支持 iOS 15+

### 7.3 里程碑 M5: 生产就绪

**交付物**:
- 性能优化报告
- 稳定性测试报告
- 兼容性测试报告
- Bug 修复清单

---

## 八、Phase 6: Beta 发布与迭代

**时间**: Week 10+  
**目标**: TestFlight 发布，收集反馈，持续迭代

### 8.1 任务清单

**Week 10: Beta 准备**

- [ ] **App Store 配置**
  - 图标与截图
  - 隐私说明
  - 描述文案
  - TestFlight 配置

- [ ] **监控与分析**
  - Crash 报告（Firebase Crashlytics）
  - 性能监控（Firebase Performance）
  - 用户行为分析
  - 错误上报

- [ ] **文档完善**
  - 用户手册
  - FAQ
  - 隐私政策
  - 服务条款

**Week 11+: 持续迭代**

- [ ] **反馈收集**
  - TestFlight 评论
  - 用户访谈
  - 数据分析

- [ ] **功能迭代**
  - 根据反馈优化
  - 新功能开发
  - Bug 修复

### 8.2 里程碑 M6: 公开发布

**交付物**:
- TestFlight 版本
- 监控仪表盘
- 用户文档
- 发布计划

---

## 九、风险管理

### 9.1 技术风险

| 风险 | 影响 | 概率 | 缓解措施 |
|------|------|------|---------|
| Opus 库集成困难 | 高 | 中 | 提前验证，准备备选方案（系统编码器） |
| 音频延迟过高 | 高 | 中 | Phase 3 尽早真机测试 |
| 无锁缓冲区数据竞争 | 中 | 低 | 使用 Swift Atomics，TSan 验证 |
| Actor 性能瓶颈 | 中 | 低 | 性能监控，减少边界跨越 |
| 真机兼容性问题 | 中 | 中 | Phase 4 多设备测试 |

### 9.2 应对策略

**风险 1: Opus 集成失败**
- **Plan A**: 使用 libopus + Swift 封装（推荐）
- **Plan B**: 使用 AVAudioConverter + AAC（质量略差）
- **Plan C**: 使用服务端编解码（延迟增加）

**风险 2: 延迟超标**
- **优化 1**: 减小音频缓冲区（512 samples）
- **优化 2**: 预测性播放
- **优化 3**: 网络优先级调优
- **降级方案**: 文本模式

**风险 3: 内存泄漏**
- **检测**: Instruments Leaks
- **预防**: Actor 弱引用、Task 取消
- **监控**: 内存警告处理

---

## 十、团队与分工

### 10.1 角色定义

| 角色 | 职责 | 人数 |
|------|------|------|
| iOS 架构师 | 架构设计、核心框架 | 1 |
| iOS 开发 | 功能实现、测试 | 2 |
| UI/UX 设计师 | 界面设计、交互 | 1 |
| QA 工程师 | 测试、Bug 跟踪 | 1 |
| Backend 工程师 | 接口对接、问题排查 | 1 |

### 10.2 协作流程

```
[设计] → [开发] → [自测] → [Code Review] → [QA 测试] → [发布]
   ↑                                                          │
   └──────────────────── Bug 修复 / 迭代 ──────────────────────┘
```

**每日站会**:
- 15 分钟
- 同步进度、阻塞、计划

**每周评审**:
- Demo 本周成果
- 里程碑验收
- 下周规划

---

## 十一、质量保证

### 11.1 代码质量

- **代码覆盖率**: >80%
- **SwiftLint**: 强制代码规范
- **Code Review**: 每个 PR 需要 1+ 人审批
- **CI 检查**: 编译、测试、Lint 自动化

### 11.2 测试策略

| 测试类型 | 覆盖率目标 | 工具 |
|---------|----------|------|
| 单元测试 | >80% | XCTest |
| 集成测试 | >60% | XCTest |
| UI 测试 | 关键流程 100% | XCUITest |
| 性能测试 | 核心路径 | XCTest Performance |
| 压力测试 | 长时间运行 | 手动 + 脚本 |

### 11.3 发布检查清单

- [ ] 所有测试通过
- [ ] 代码覆盖率达标
- [ ] 性能指标达标
- [ ] 真机测试通过
- [ ] Code Review 完成
- [ ] 文档更新
- [ ] Release Notes 编写

---

## 十二、时间轴

```
Week 1    Week 2    Week 3    Week 4    Week 5    Week 6    Week 7    Week 8    Week 9    Week 10+
│         │         │         │         │         │         │         │         │         │
├─ P0 ────┤         │         │         │         │         │         │         │         │
│         ├─ P1 ────┴─────────┤         │         │         │         │         │         │
│         │                   ├─ P2 ────┤         │         │         │         │         │
│         │                   │         ├─ P3 ────┴─────────┤         │         │         │
│         │                   │         │                   ├─ P4 ────┤         │         │
│         │                   │         │                   │         ├─ P5 ────┴─────────┤
│         │                   │         │                   │         │                   ├─ P6...
│         │                   │         │                   │         │                   │
▼         ▼                   ▼         ▼                   ▼         ▼                   ▼
M0        M1                  M2        M3                  M4        M5                  M6
基础      核心框架             WebSocket  音频链路             MVP       生产就绪             发布
```

---

## 十三、成功指标

### 13.1 技术指标

| 指标 | 目标值 | 测量方法 |
|------|--------|---------|
| 首帧延迟 | < 300ms | 用户松开 → 听到第一个音频块 |
| 端到端延迟 | < 1.5s | 用户松开 → 听到完整回复开始 |
| 音频块间隔 | 20-50ms | 相邻音频块播放间隔 |
| 崩溃率 | < 0.1% | 每 1000 次会话 < 1 次 |
| 内存占用 | < 50MB | Instruments 测量 |
| CPU 占用 | < 20% | 音频处理峰值 |
| 代码覆盖率 | > 80% | Xcode Coverage |

### 13.2 业务指标

| 指标 | 目标值 | 测量方法 |
|------|--------|---------|
| 对话完成率 | > 90% | 开始录音 → 完整播放 AI 回复 |
| 用户满意度 | > 4.0/5.0 | App Store 评分 |
| 日活跃用户 | 增长 | Analytics |
| 平均对话轮次 | > 5 | Analytics |

---

## 十四、下一步行动

### 立即行动（本周）

1. **环境准备**
   - 创建 Xcode 项目
   - 配置 SPM 依赖
   - 设置 CI/CD

2. **设计验证**
   - 团队评审架构设计文档
   - 确认 Backend 接口兼容性
   - 验证 Opus 库可用性

3. **团队组建**
   - 确认团队成员
   - 分配角色职责
   - 建立协作流程

### 短期计划（两周内）

4. **Phase 1 启动**
   - 实现协议定义
   - 实现状态机
   - 编写核心测试

5. **技术预研**
   - Opus 库编译与集成
   - 无锁缓冲区原型
   - 音频采集 Demo

### 中期目标（一个月）

6. **M2 达成**
   - WebSocket 通信完成
   - 可以与 Backend 建立连接
   - 消息收发正常

7. **M3 推进**
   - 音频采集原型
   - 编解码验证
   - 真机测试准备

---

## 总结

### 实施路线图特点

1. **风险前置**: Phase 2-3 优先解决最大技术风险（WebSocket + 音频）
2. **增量交付**: 每个 Phase 都有明确的里程碑和 Demo
3. **快速迭代**: 9 周完成 MVP，持续优化
4. **质量保证**: 测试覆盖率、性能指标、真机验证

### 关键里程碑

- **M1 (Week 3)**: 核心框架 - 可通过 Mock 模拟对话
- **M2 (Week 4)**: WebSocket - 可与 Backend 文本通信
- **M3 (Week 6)**: 音频链路 - 可录制并播放语音
- **M4 (Week 7)**: MVP - 完整对话功能
- **M5 (Week 9)**: 生产就绪 - 性能优化完成
- **M6 (Week 10+)**: 公开发布 - TestFlight 上线

### 资源需求

- **团队规模**: 6 人
- **开发周期**: 9 周（MVP）+ 持续迭代
- **硬件需求**: iPhone 测试机（3-5 台）

这是一个可执行、可验证、风险可控的实施计划。
