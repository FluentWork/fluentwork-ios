# iOS W3/W4 Skills-to-Ticket 索引

**日期**: 2026-09-06
**仓库**: `FluentWork/fluentwork-ios`
**方法论**: Matt Pocock Skills-to-Ticket

## 1. 全量 Skill 总览(8 个)

| Skill | 优先级 | Sub-tickets | 总工时 | 启动条件 | 关联 backend |
|---|---|---|---|---|---|
| **I20** Prompt 工程师接入 | P0 | 4 (T-I20-1..4) | 0.5d | **W3 Day 1**, 无依赖 | 无 |
| **I21** 状态机子状态扩展 | P0 | 4 (T-I21-1..4) | 0.5d | **W3 Day 1**, 无依赖 | 无 |
| **I15** TTS 播放集成 | P0 | 5 (T-I15-1..5) | 1.0d | W3 Day 3 | B17 CLOSED |
| **I14** 创建练习弹层 | P1 | 4 (T-I14-1..4) | 1.0d | W4 Day 1 | B21 CLOSED |
| **I16** 完整转录浮层 | P1 | 4 (T-I16-1..4) | 1.0d | W4 Day 2 | B18 CLOSED |
| **I17** 闪测 UI | P0 | 6 (T-I17-1..6) | 1.5d | W4 Day 3 | B22 CLOSED |
| **I18** 话题卡 UI | P1 | 5 (T-I18-1..5) | 1.0d | W4 Day 4 | B23 CLOSED |
| **I19** 历史回顾列表 | P2 | 4 (T-I19-1..4) | 0.5d | W4 Day 5 | B24 CLOSED |
| **合计** | — | **36** | **7.0d** | — | — |

## 2. 文件 → Ticket 映射

| 文件 | Skill | 包含 |
|---|---|---|
| `01-skill-I20-prompt.md` | I20 | I20 master + T-I20-1..4 |
| `02-skill-I21-state-machine.md` | I21 | I21 master + T-I21-1..4 |
| `03-skill-I15-tts.md` | I15 | I15 master + T-I15-1..5 |
| `04-skill-I14-create-practice.md` | I14 | I14 master + T-I14-1..4 |
| `05-skill-I16-review-ui.md` | I16 | I16 master + T-I16-1..4 |
| `06-skill-I17-drill-ui.md` | I17 | I17 master + T-I17-1..6 |
| `07-skill-I18-topic-cards.md` | I18 | I18 master + T-I18-1..5 |
| `08-skill-I19-history.md` | I19 | I19 master + T-I19-1..4 |

## 3. 完整依赖图

```
W3 Day 1(无 backend 阻塞,可立即启动):
  I20 (T-I20-1..4) ──▶  全部 P0
  I21 (T-I21-1..4) ──▶  全部 P0
  这两个可并行给 2 个 iOS 工程师

W3 Day 3:
  I15 (T-I15-1..5) ──▶ B17 TTS Provider CLOSED

W4 Day 1:
  I14 (T-I14-1..4) ──▶ B21 素材模块 CLOSED

W4 Day 2:
  I16 (T-I16-1..4) ──▶ B18 review eval CLOSED

W4 Day 3:
  I17 (T-I17-1..6) ──▶ B22 闪测 CLOSED
                └─▶ I15 TTSPlayer(共享 Opus 解码器)

W4 Day 4:
  I18 (T-I18-1..5) ──▶ B23 话题卡 CLOSED
                └─▶ SpeakingRoomView(已 live)

W4 Day 5:
  I19 (T-I19-1..4) ──▶ B24 历史回顾 API CLOSED
                └─▶ I16 SessionReviewView(复用)
```

## 4. 推荐分工(2 人可覆盖 W3,扩到 3-4 人 W4)

| 人员 | W3 任务 | W4 任务 |
|---|---|---|
| **iOS 工程师 A** | I20(0.5d) + I21(0.5d) | I16(1.0d) + I19(0.5d) |
| **iOS 工程师 B** | I15(1.0d) | I14(1.0d) + I18(1.0d) |
| **iOS 工程师 C(可选)** | — | I17(1.5d,工作量最大) |

## 5. 关键约束

- ✅ 每个 ticket 工时 ≤ 0.5 dev-day
- ✅ 每个 ticket 独立可 PR / 单独 merge / 单独回滚
- ✅ acceptance criteria 量化(Swift test name + UI 截图描述)
- ✅ ticket body 必须显式写 `Blocked by #X` 或 `depends on IXX`
- ❌ 不允许把 ticket 写成「做 I15 的某部分」(过粗)
- ❌ 不允许跨 skill 拆 ticket(如把 I17 拆到 I20 那边)
- ❌ 不允许在 iOS repo 建 master issue(本期仅在 .scratch/ 本地,待后端开完对应 ticket 后再正式建仓)

## 6. iOS 已有代码资产(复用)

| 路径 | 用途 | 被哪些 skill 复用 |
|---|---|---|
| `Shared/FluentWorkCore/SpeechSession/SpeechSessionMachine.swift` | 状态机 | I20, I21, I15, I17 |
| `Shared/FluentWorkCore/SpeechSession/SpeechSessionState.swift` | 状态枚举 | I21 |
| `Shared/FluentWorkCore/Services/LiveAudioEngine.swift` | 实时音频 | I15, I17 |
| `Shared/FluentWorkNetworking/SessionAPIClient.swift` | 会话 API | I16, I19 |
| `Shared/FluentWorkNetworking/CorpusAPIClient.swift` | 语料 API | I14, I17 |
| `Shared/FluentWorkCore/Services/AuthenticatedNetworkClient.swift` | 鉴权网络层 | 所有 skill |
| `Shared/FluentWorkDiagnostics/Tracker.swift` | 埋点 | I20, I21 |
| `Shared/FluentWorkCore/Navigation/AppRootTabView.swift` | 导航 | I18, I19 |
| `App/FluentWorkHost/HostRootView.swift` | 根视图 | I14, I18 |

## 7. GitHub 落库时机

iOS 本期**先在 .scratch/ 本地切分**,等以下条件满足后再正式建仓:

1. **W3 Day 1 建仓**:I20 + I21(无 backend 阻塞)
2. **W3 Day 3 建仓**:I15(B17 CLOSED 后)
3. **W4 建仓**:I14/I16/I17/I18/I19(B21/B18/B22/B23/B24 CLOSED 后)

当前阶段:本地草稿 → 等 backend 对应 ticket CLOSED
