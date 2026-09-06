# iOS W3/W4 Issue 切分 — Skills-to-Ticket 工作目录

**创建日期**: 2026-09-06
**仓库**: `FluentWork/fluentwork-ios`

## 快速导航

| 文件 | 内容 |
|---|---|
| `README.md` | 本文件 |
| `INDEX.md` | 8 skills 全量索引 + 依赖图 |
| `01-skill-I20-prompt.md` | I20 Prompt 工程师接入(4 sub-tickets) |
| `02-skill-I21-state-machine.md` | I21 状态机子状态扩展(4 sub-tickets) |
| `03-skill-I15-tts.md` | I15 TTS 播放集成(5 sub-tickets) |
| `04-skill-I14-create-practice.md` | I14 创建练习弹层(4 sub-tickets) |
| `05-skill-I16-review-ui.md` | I16 完整转录浮层(4 sub-tickets) |
| `06-skill-I17-drill-ui.md` | I17 闪测 UI(6 sub-tickets) |
| `07-skill-I18-topic-cards.md` | I18 话题卡 UI(5 sub-tickets) |
| `08-skill-I19-history.md` | I19 历史回顾列表(4 sub-tickets) |

## 方法论

使用 [Matt Pocock Skills-to-Ticket](https://github.com/FluentWork/fluentwork-meta/blob/main/agents/shared/matt-pocock-skills.md):
- 每个 ticket 工时 ≤ 0.5 dev-day
- 每个 ticket 独立可 PR / 单独 merge / 单独回滚
- acceptance criteria 量化(Go test name 不适用,改用 Swift test name + UI 截图)
- 阻塞关系显式写出

## 状态约定

```
🟡 本地草稿(.scratch/, tracked)
   ↓ review 通过
🟢 提交到 GitHub(创建 issue)
   ↓ 开始实施
🔵 进行中
   ↓ PR merged
✅ CLOSED
```

## 对应关系

- 启动包: `fluentwork-meta/docs/40_研发流程与协作/60_iOS_W3_W4_代码层启动包_2026-09-06.md`
- iOS 设计文档: `fluentwork-meta/docs/30_技术方案/32_FluentWork-iOS App端技术设计文档.md`
- REST 契约: `fluentwork-meta/docs/30_技术方案/48_FluentWork_V2_REST接口契约冻结_2026-09-06.md`
- backend W3 启动包: `fluentwork-meta/docs/40_研发流程与协作/55_FluentWork_V2_W3_代码层启动包_2026-09-06.md`
