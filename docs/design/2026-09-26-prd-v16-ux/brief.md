# 09-26 稿子快照（PRD V1.6 → UI/UX）

## 来源与可追溯

| 项 | 值 |
|---|---|
| open-design 项目 | `PRD 转 UI/UX 文档` |
| project id | `09d2063a-de09-40c6-9772-02ab1cda447b` |
| 数据根 | `~/.od/projects/09d2063a-de09-40c6-9772-02ab1cda447b/index.html` |
| 生成 run | `e6fba63b-d6bc-4644-bf1d-2e9f8f253488`（status `succeeded`） |
| linkedDirs | `fluentwork-meta` |
| 快照时间 | 2026-09-29 |
| `index.html` sha256 | `5971251977c787ab0b581d97b3a7befee83686e0a30092b3d2fd2671a4423945` |

抓取方式：拷贝活文件（`~/.od/projects/<id>/index.html`），不是「导出再回贴」。
重新生成稿子后，这个 sha 会变 —— 换 sha 就是一次设计变更，必须同步 `../DESIGN.md` 与
`DesignTokens.swift`，并让 `DesignTokensTests` 的手写对照表跟着走。

**用法**：直接用浏览器打开 `index.html`（单文件，图标是内联 SVG，无外链）。它是视觉契约，不是产物。

## 文档结构（9 段）

| 段 | 内容 |
|---|---|
| 01 | 设计目标与原则（5 条：效率优先于愉悦 / 降低开口焦虑 / 状态永远可见 / 进步可视化 / 深色优先） |
| 02 | 设计系统（色 / 字 / 间距圆角 / 组件 / 图标）→ 已抽成 `../DESIGN.md` |
| 03 | 信息架构与导航 + 关键路径长度审计 |
| 04 | **核心页面高保真稿（14 个 393×852 手机框）** |
| 05 | PRD V1.6 变化点（21_ 挂账的待吸收项，本文的落地结果） |
| 06 | 动效与语音状态（说的房间的语音状态机） |
| 07 | 空态与错误态（8 个场景） |
| 08 | 无障碍 |
| 09 | 覆盖对照（按页面 / 按功能模块 / 明确不在范围内） |

## 屏号索引 × iOS 现状（2026-09-29 实测）

`App/FluentWorkHost/HostRootView.swift` 的 `flashRoot` 目前是 `Text("闪测（占位）")`。

| 屏 | 页面 | iOS 落点 | 状态 |
|---|---|---|---|
| 01 | 工作台（首页） | `FluentWorkUI/Workbench/WorkbenchHomeView.swift` | 有视图，未对齐令牌 |
| 02 | 说的房间 · 对话中 | `FluentWorkUI/SpeakingRoom/SpeakingRoomView.swift` | 有视图，未对齐令牌 |
| 03 | 说的房间 · 卡壳救援 | 同上（B8 用户自取那一格） | 部分 |
| 04 | 回顾页 | `FluentWorkUI/Review/ReviewRootView.swift` | 有视图，未对齐令牌 |
| 05 | 闪测 · 答题（E1/E4/E5） | — | **缺** |
| 06 | 闪测 · 判定与申诉（E2） | — | **缺** |
| 07 | 闪测 · 结算 | — | **缺** |
| 08 | 语料库 | `FluentWorkUI/Corpus/CorpusRootView.swift` | 有视图，缺进步证据 |
| 09 | 每日一读 | `FluentWorkUI/DailyRead/DailyReadRootView.swift` | 有视图，缺跟读自评 |
| 10 | 话题建议页（H1–H3） | — | **缺** |
| 11 | 创建练习弹层（A1/A2） | — | **缺（关键路径）** |
| 12 | 设置页 | `FluentWorkUI/Settings/SettingsRootView.swift` | 有视图，未对齐令牌 |
| 13 | 订阅页 | — | **后置**（`21_` §4.8：MVP 期入口隐藏，服务端开关） |
| 14 | 回顾页 · 段落层 | — | **缺** |

另有 `FluentWorkUI/SessionHistory/SessionHistoryRootView.swift`（屏 01 的历史列表）、
`BadgeFeedback/BadgeFeedbackOverlay.swift`（屏 02 的 B7 徽章）。

## 稿子自述的边界

- **发音评测（模块 I，I1–I4）整体后置到 V1.1**，只在屏 06 与屏 09 预留位置。
- **订阅与商业化的完整形态**后置到 V1.1 商业化启动时细化。
- **Android 不在范围内**（PRD §9.1：Android 在 V2.0 视 iOS 留存数据决策），本文按 iOS 17+ 单平台出稿。
- **浅色主题**未出稿；深色为默认。
- `23_理想UX交互纲要` 中标「待评审」的两条（关键词镜像、语料库按未来会议组织）**未进入形态**。
- 稿子里演示数据、订阅价格均为占位符。

## 本仓的取用约定

```
docs/design/
├── DESIGN.md                        # 令牌唯一来源（人读）
└── 2026-09-26-prd-v16-ux/
    ├── brief.md                     # 本文件
    ├── index.html                   # 稿子快照（便于 diff 与追溯）
    └── shots/                       # before / after 截图
```
