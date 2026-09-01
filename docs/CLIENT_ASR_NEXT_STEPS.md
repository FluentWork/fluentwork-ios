# Client ASR 下一步行动计划

**当前状态**：✅ iOS 实现完成 + 测试通过 + 文档齐全  
**PR 状态**：[#39](https://github.com/FluentWork/fluentwork-ios/pull/39) - Open  
**更新时间**：2026-09-01

---

## 一、已完成的工作 ✅

### 1.1 实现部分
- ✅ PCM 缓冲逻辑（`SpeechSessionMiddleware.swift`）
- ✅ 动态数组实现（`var pcmBuffer: [Data] = []`）
- ✅ 生命周期管理（speechStarted → capture → speechEnded → clear）
- ✅ ClientASR 集成（`transcribeWithClientASR` 使用真实 PCM）
- ✅ 超时机制（800ms 竞速）
- ✅ Fallback 机制（超时/不可用 → text=nil）

### 1.2 测试部分
- ✅ 7 个单元测试全部通过（0.976s）
- ✅ Mock 架构（RecordingClientASRTranscriber, ControllableAudioEngine）
- ✅ 测试覆盖率：成功/超时/不可用/缓冲/清理/隐私/遥测

### 1.3 文档部分
- ✅ `README_CLIENT_ASR_TESTS.md`（测试架构说明）
- ✅ `I13_client_asr_implementation_summary.md`（实现总结）
- ✅ `CLIENT_ASR_WHY_AND_VALUE.md`（场景与价值分析）

### 1.4 Bug 修复
- ✅ 修复 `BootstrapSurfaceExamples.swift` 的 import warning
- ✅ 修复测试文件的类型歧义（TestStore 等）

---

## 二、当前 PR 状态

### PR #39: feat(client-asr): Add comprehensive test suite for ClientASR integration

**提交记录**：
1. `a2378da` - 测试套件 + 文档 + import 修复
2. `aee3049` - PCM 缓冲实现 + 测试修复
3. `0aebe4a` - 场景价值文档

**统计**：
- +1,624 行
- -23 行
- 3 commits

**审阅者**：
- FluentWork/core (Requested)
- FluentWork/ios (Requested)

---

## 三、下一步行动（按优先级）

### 🔴 P0：PR 合并前必做

#### 1. 代码审查
- [ ] **iOS 团队审查**（预计 1-2 天）
  - 检查 PCM 缓冲实现的内存安全性
  - 验证 Middleware 集成的并发安全
  - 确认测试覆盖率是否充分

- [ ] **Backend 团队审查**（预计 0.5 天）
  - 确认 `user.speech.end.text` 字段格式
  - 验证 Backend 能否正确处理 `text=nil`
  - 确认遥测事件命名一致性

#### 2. 手动测试验证
- [ ] **本地真机测试**（预计 0.5 天）
  ```bash
  # 测试场景
  1. 正常说话 → 检查 text 是否正确发送
  2. 说很长句子 → 检查是否触发超时
  3. 关闭语音识别权限 → 检查 fallback
  4. 查看 Xcode console → 验证三个埋点事件
  ```

#### 3. 修复 PR description
- [ ] **更新 PR body**
  - 补充最新的 3 个 commit
  - 添加 `CLIENT_ASR_WHY_AND_VALUE.md` 链接
  - 更新统计数据（+1624 -23）

### 🟡 P1：Phase 2 联调前准备

#### 4. Backend 配合工作
- [ ] **Backend 实现 text 字段接收**（B13 ticket）
  ```json
  // user.speech.end 帧格式
  {
    "type": "user.speech.end",
    "turn_id": "turn-1",
    "text": "今天学习了 Redux middleware"  // ← 新增字段
  }
  ```

- [ ] **Backend 实现 fallback 逻辑**
  ```python
  # 伪代码
  if message.text is None:
      # 调用豆包 ASR
      text = await volcengine_asr.transcribe(audio_buffer)
  else:
      # 使用 iOS 提供的 text
      text = message.text
  
  # 继续 hit detection
  badges = badge_detector.detect(text)
  ```

#### 5. 环境准备
- [ ] **Backend 部署测试环境**
  - 部署 B13 代码到 staging
  - 配置 `VOICE_CLIENT_ASR_REQUIRED=false`（联调阶段不强制）
  - 配置遥测事件接收（Prometheus + Grafana）

- [ ] **iOS 构建 TestFlight 版本**
  - 创建 `client-asr-beta` 构建
  - 邀请测试用户（内部团队）
  - 准备 Xcode Instruments 性能监控

#### 6. 联调清单准备
- [ ] **创建联调文档**（见下方模板）
  - 4 个测试 Case
  - 期望结果定义
  - 失败回滚步骤

### 🟢 P2：Phase 3 灰度前优化

#### 7. FeatureFlag 实现
- [ ] **添加 `enableClientASR` flag**
  ```swift
  // FeatureFlags.swift
  public enum AppFeatureFlag: String {
      case enableClientASR  // ← 新增
      // ... existing flags
  }
  
  // AppDependencies.swift
  var clientASRTranscriber: Factory<ClientASRTranscriber> {
      self {
          let flags = Container.shared.featureFlags()
          if flags.isEnabled(.enableClientASR) {
              return AppleSpeechClientASRTranscriber()
          } else {
              return RawClientASRTranscriber()
          }
      }
  }
  ```

- [ ] **配置 Remote Config**
  - Firebase / Launch Darkly 设置
  - 默认值：`enabled: true, rollout: 0%`

#### 8. 监控 Dashboard
- [ ] **Backend 监控指标**
  ```yaml
  # Prometheus metrics
  - speech_client_asr_received_total (text 非空的请求数)
  - speech_client_asr_fallback_total (text 为空的请求数)
  - speech_client_asr_success_rate (成功率)
  - badge_hit_detection_latency_ms (命中延迟)
  ```

- [ ] **iOS 埋点验证**
  ```swift
  // 确认三个事件能正确上报
  - speech_client_asr_completed
  - speech_client_asr_skipped
  - speech_client_asr_failed
  ```

---

## 四、Phase 2 联调详细计划

### 4.1 联调环境

| 组件 | 环境 | 配置 |
|------|------|------|
| **iOS** | TestFlight Beta | `feat/client-asr-b13` branch |
| **Backend** | Staging | B13 实现 + `VOICE_CLIENT_ASR_REQUIRED=false` |
| **数据库** | Staging DB | 隔离的测试数据 |
| **监控** | Grafana Staging | 实时查看指标 |

### 4.2 联调 Case

#### Case 1: 正常识别成功 ✅

**步骤**：
1. iOS 启动 app，进入 Speaking Room
2. 点击麦克风，说话："今天学习了 Redux middleware 的实现原理"
3. 停止说话

**iOS 预期**：
- Xcode console 显示：
  ```
  [ClientASR] Transcription completed in 320ms
  [Tracker] speech_client_asr_completed {
    turn_id: "turn-1",
    elapsed_ms: 320,
    text_length: 39
  }
  ```

**Backend 预期**：
- Logs 显示：
  ```
  INFO voice user speech frame type=user.speech.end text="今天学习了..."
  INFO badge hit detection using client_asr_text
  INFO badge matched: "Redux 架构笔记"
  ```

#### Case 2: 超时 fallback ⏱️

**步骤**：
1. 说很长的句子（15 秒以上）
2. 停止说话

**iOS 预期**：
```
[ClientASR] Transcription timeout after 800ms
[Tracker] speech_client_asr_skipped { reason: "timeout" }
```

**Backend 预期**：
```
INFO voice user speech frame type=user.speech.end text=null
INFO calling volcengine ASR for fallback
INFO badge hit detection using server_asr_text
```

#### Case 3: 权限拒绝 fallback ❌

**步骤**：
1. 设置 → 隐私 → 语音识别 → 关闭 FluentWork
2. 说话："测试权限拒绝"
3. 停止说话

**iOS 预期**：
```
[ClientASR] Authorization denied
[Tracker] speech_client_asr_failed {
  error_code: "authorization_denied"
}
```

**Backend 预期**：
```
INFO voice user speech frame type=user.speech.end text=null
INFO calling volcengine ASR for fallback
```

#### Case 4: Badge 命中率对比 📊

**步骤**：
1. 准备 50 个测试句子（覆盖不同主题）
2. 分别用 Client ASR 和 Server ASR 识别
3. 对比 Badge 命中结果

**统计指标**：
- Client ASR 命中率：XX%
- Server ASR 命中率：YY%
- 差异：±5% 以内为合格

### 4.3 联调通过标准

- [x] Case 1-3 全部通过
- [x] iOS 三个埋点事件正常触发
- [x] Backend logs 能看到 `text` 字段
- [x] Badge 命中率差异 < 5%
- [x] 无崩溃/ANR/内存泄漏

---

## 五、风险与预案

### 5.1 可能的问题

| 问题 | 概率 | 影响 | 预案 |
|------|------|------|------|
| **PR 审查发现设计问题** | 中 | 高 | 修改实现，重新测试 |
| **Backend 接口不兼容** | 低 | 高 | Backend 先支持可选 text，后续强制 |
| **联调发现 Badge 命中率下降** | 中 | 中 | 调整超时时间，或提升准确率阈值 |
| **iOS 内存占用过高** | 低 | 中 | 限制 buffer 最大 30 秒 |
| **遥测事件未上报** | 低 | 低 | 检查 Tracker 配置 |

### 5.2 回滚策略

**紧急回滚**（如果 PR 合并后出现严重问题）：
```swift
// 立即关闭 Client ASR
Container.shared.clientASRTranscriber.register {
    RawClientASRTranscriber()  // 返回 nil，全部 fallback
}
```

**灰度回滚**（Phase 3 时）：
```yaml
# Remote config
enableClientASR:
  enabled: false
  rollout: 0%
```

---

## 六、时间估算

| 阶段 | 任务 | 预计耗时 | 负责人 |
|------|------|---------|--------|
| **PR 审查** | iOS 审查 | 1-2 天 | iOS Team |
| **PR 审查** | Backend 审查 | 0.5 天 | Backend Team |
| **PR 合并** | 修复反馈 + 合并 | 0.5-1 天 | iOS Team |
| **Backend 实现** | B13 text 字段支持 | 1-2 天 | Backend Team |
| **环境准备** | TestFlight + Staging | 0.5 天 | DevOps |
| **联调测试** | 4 个 Case 验证 | 1 天 | iOS + Backend |
| **FeatureFlag** | 实现 + Remote Config | 0.5 天 | iOS Team |
| **监控 Dashboard** | Grafana 配置 | 0.5 天 | Backend Team |

**总计**：5-8 个工作日（预计 2026-09-02 ~ 09-10 完成 Phase 2-3）

---

## 七、Checklist

### 立即行动（今天）
- [ ] 通知 iOS 团队审查 PR #39
- [ ] 通知 Backend 团队开始 B13 实现
- [ ] 创建联调文档（Google Doc / Notion）

### 本周完成（09-02 ~ 09-06）
- [ ] PR #39 合并到 `main`
- [ ] Backend B13 部署到 staging
- [ ] 完成 Phase 2 联调

### 下周完成（09-09 ~ 09-13）
- [ ] FeatureFlag 实现 + Remote Config 配置
- [ ] 监控 Dashboard 上线
- [ ] Phase 3 灰度 10%

---

## 八、联系人

| 角色 | 姓名 | 职责 |
|------|------|------|
| **iOS Lead** | @tangzzz | 实现负责人、联调协调 |
| **Backend Lead** | @backend-lead | B13 实现、联调验证 |
| **QA** | @qa-team | 联调测试、Case 验证 |
| **DevOps** | @devops | 环境准备、监控配置 |
| **Product** | @pm | 灰度决策、上线审批 |

---

## 九、相关文档

- 📄 [PR #39](https://github.com/FluentWork/fluentwork-ios/pull/39) - iOS 实现 PR
- 📄 [CLIENT_ASR_WHY_AND_VALUE.md](./CLIENT_ASR_WHY_AND_VALUE.md) - 场景价值分析
- 📄 [I13_client_asr_implementation_summary.md](./I13_client_asr_implementation_summary.md) - 实现总结
- 📄 [README_CLIENT_ASR_TESTS.md](../Tests/FluentWorkCoreTests/Architecture/README_CLIENT_ASR_TESTS.md) - 测试文档
- 📄 Backend B13 ticket（待链接）
- 📄 联调文档（待创建）

---

**最后更新**：2026-09-01  
**下次更新**：PR #39 合并后
