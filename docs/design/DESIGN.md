# FluentWork iOS 设计令牌（DESIGN.md）

> **视觉常量只有这一个出处。** 稿子与代码都对齐本文；本文对齐 09-26 稿子。

## 0. 这份文档的地位

| 角色 | 是谁 | 说明 |
|---|---|---|
| 设计语言 | `fluentwork-meta/docs/20_产品设计/21_FluentWork界面设计文档.md` | V1.2，对应 PRD V1.6。色彩方向与六条原则的唯一上游 |
| 设计形态（**本文件的来源**） | `docs/design/2026-09-26-prd-v16-ux/index.html` | 2026-09-26 由 open-design 生成的「PRD 转 UI/UX 文档」，14 屏高保真稿。**P0 拍板以它为准** |
| **可执行真源** | `Shared/FluentWorkUI/DesignTokens/DesignTokens.swift` | 代码里的常量。**与本文不一致时以代码为准**，并在同一次提交里改回本文 |

**本文不是门禁的一部分**（`AGENTS.md` Local Rule 1：文档不进落地门）。守卫在
`Tests/FluentWorkCoreTests/UI/DesignTokensTests.swift`，它拿一张**手写**的「稿子变量 → Swift 路径 → 期望值」
对照表逐条比对 —— 与 backend `internal/httpserver/openapi_contract_test.go` 同一写法。

### 为什么需要这份文档（2026-09-29 实测）

在本文出现之前，视觉常量有**三份且互相矛盾**：稿子（teal）、meta `21_`（teal）、
iOS `DesignTokens.swift`（蓝色板 `#0B0F14` / `#3D8BFF`，`6dcabd0`，2026-08-25）。
代码那份晚于锁定语言一天却从未采用它。同一时期，`Shared/FluentWorkUI/` 的视图
**一处都没用过** `DesignTokens`，全部走系统语义色（`.secondary` ×32、`.red` ×5、
`Color.blue` ×4 …）——也就是说设计系统当时只活在文档里，一行都没进代码。

---

## 1. 色彩

方向：**冷灰蓝绿（slate / teal）**。错误色刻意避开纯红 —— 语言学习里的「错误」是中性事件，不是失败
（`21_` 原则 2）。所以本套色板**没有 danger / red**；失败与待改进用 `training` / `improve`。

| 稿子变量 | Swift 路径 | 值 | 用途 | AA 对比度（底 `#1A2226`） |
|---|---|---|---|---|
| `--fw-bg` | `DesignTokens.Hex.background` | `#1A2226` | 页面底色 | — |
| `--fw-bg-elev` | `DesignTokens.Hex.backgroundElevated` | `#232E33` | 卡片、弹层底 | — |
| `--fw-brand` | `DesignTokens.Hex.brand` | `#4A7C82` | 激活态、图标、装饰性填充 | `3.46:1` ✗ **不得作正文色** |
| `--fw-brand-strong` | `DesignTokens.Hex.brandStrong` | `#35646A` | 实心主按钮底 | 底上 `2.45:1`；**配 `textPrimary` `5.59:1` ✓** |
| `--fw-accent` | `DesignTokens.Hex.accent` | `#7FB3B8` | 高亮、链接、命中徽章、**英文话术块正文** | `6.95:1` ✓ |
| `--fw-text` | `DesignTokens.Hex.textPrimary` | `#E8EDEF` | 正文 | `13.68:1` ✓ |
| `--fw-text-2` | `DesignTokens.Hex.textSecondary` | `#9AABAF` | 说明、时间戳 | `6.78:1` ✓ |
| `--fw-success` | `DesignTokens.Hex.success` | `#6A9E7E` | 状态灯「已自动化」、正向反馈 | `5.23:1` ✓ |
| `--fw-training` | `DesignTokens.Hex.training` | `#C9A45C` | 状态灯「训练中」、温和提醒、**闪测失败** | `6.88:1` ✓ |
| `--fw-improve` | `DesignTokens.Hex.improve` | `#C97B5C` | 「待改进」标注、差异词下划线 | `4.98:1` ✓ |
| `--fw-line` | `DesignTokens.Hex.separatorBase` + `Alpha.separator` | `#E8EDEF` @ `0.10` | 分隔线、卡片描边 | — |
| `--fw-line-strong` | `Hex.separatorBase` + `Alpha.separatorStrong` | `#E8EDEF` @ `0.20` | 强调描边、sheet 手柄、列表圆点 | — |
| `--fw-wash` | `Hex.accent` + `Alpha.wash` | `#7FB3B8` @ `0.12` | 命中/选中态的浅底 | — |

上表的对比度是**按 WCAG 2.1 相对亮度公式重算**的（`DesignTokensTests` 用同一公式复查，
底为 `#1A2226`）。稿子 §2.1 印的是 `3.4 / 6.8 / 13.2 / 6.6 / 5.1 / 6.7 / 4.9`，与重算值相差
不到 0.5，**每一条的 AA 判定结果都一致**；`brandStrong` 配 `textPrimary` 的 5.5:1 是稿子自己印的。

### 不进 App 令牌的两个（稿子文档自身的底色）

| 稿子变量 | 值 | 为什么排除 |
|---|---|---|
| `--fw-bg-sunken` | `#141A1D` | 只用在 `body` 与文档左侧导航，是**文档外壳**的底色 |
| `--fw-bg-stage` | `#10161A` | 只用在 `.phone-stage`，是**手机框背后的展台** |

### 两处对 `21_` 的加固（方向没变，只改用法）

- 英文话术块正文：`21_` 原定主品牌色 `#4A7C82`（稿子印 3.4:1，低于 AA 正文线）⇒ 改用 `accent` `#7FB3B8`（稿子印 6.8:1）。
- 实心主按钮底 `#4A7C82` 配 `#E8EDEF` 只有 3.9:1 ⇒ 加深为 `brandStrong` `#35646A`（稿子印 5.5:1）；
  `#4A7C82` 保留给激活态、图标与装饰性填充。

---

## 2. 字体与排版

不引入自定义字体（控包体积）。中文系统默认（PingFang SC），英文系统无衬线（SF Pro Text），
技术术语与代码片段用 SF Mono。**英文内容同字号、字重加一级**，保证中英混排可读。

| 用途 | Swift 路径 | 值 |
|---|---|---|
| 页面标题 | `Typography.titlePointSize` | 20pt / Bold |
| 卡片标题 | `Typography.cardTitlePointSize` | 16pt / Bold |
| 正文 | `Typography.bodyPointSize` | 15pt / Regular，行高 ×1.5 |
| 辅助文本 | `Typography.captionPointSize` | 13pt / Regular |
| 英文话术块 | `Typography.englishPhrase` | 15pt / Medium / 色 `accent` |
| 技术术语 | `Typography.mono` | SF Mono 15pt |

字重：`titleWeight` / `cardTitleWeight` = `.bold`，`bodyWeight` / `captionWeight` = `.regular`，
英文话术块 `englishPhraseWeight` = `.medium`（即「字重 +1」的落点）。
行高：`bodyLineHeightMultiple` = `1.5`。

正文基准 **15pt**，高于系统最小可读线；动态字体最大放到 **130%** 时布局不得破裂。

---

## 3. 间距与圆角

间距只取 4 的倍数。页面左右安全边距 **16pt**。

| 稿子变量 | Swift 路径 | 值 | 用途 |
|---|---|---|---|
| `--fw-s1` | `Spacing.s1` | 4pt | 图标与文字 |
| `--fw-s2` | `Spacing.s2` | 8pt | 同组元素 |
| `--fw-s3` | `Spacing.s3` | 12pt | 卡片内块间距 |
| `--fw-s4` | `Spacing.s4` | 16pt | 页面边距、卡片内边距 |
| `--fw-s6` | `Spacing.s6` | 24pt | 卡片之间 |
| `--fw-s8` | `Spacing.s8` | 32pt | 区块之间 |
| — | `Spacing.pageMargin` | 16pt | 页面左右安全边距（= `s4`，独立命名以免被误调） |

| 稿子变量 | Swift 路径 | 值 | 用途 |
|---|---|---|---|
| `--fw-r-card` | `Radius.card` | 12pt | 卡片 |
| `--fw-r-bubble` | `Radius.bubble` | 16pt | 对话气泡 |
| `--fw-r-btn` | `Radius.capsule` | 24pt | 胶囊按钮 |

---

## 4. 动效

动效只有三个用途：说明状态变化、说明层级关系、说明一个动作的结果。
**任何纯装饰的动效都不做**（工程师用户，花哨扣分）。

| 稿子变量 | Swift 路径 | 值 | 用途 |
|---|---|---|---|
| `--fw-d-micro` | `Motion.microSeconds` | `0.18`（150–200ms 档） | 微交互：徽章弹出、按钮反馈 |
| `--fw-d-trans` | `Motion.transitionSeconds` | `0.28`（250–300ms 档） | 页面转场：右推 / 上滑 |
| `--fw-ease` | `Motion.controlPoints` | `(0.22, 0.61, 0.36, 1)` ease-out | 统一缓动 |
| — | `Motion.exitDurationRatio` | `0.65` | 退出时长 = 入场 × 0.65（取 60–70% 档） |

对应动画值：`Motion.micro` / `Motion.transition`（ease-out 曲线 + 上表时长）、
`Motion.microExit` / `Motion.transitionExit`（`.easeIn` + 缩过的时长）。

配套规则：**退出时长取入场的 60–70%**，退出用 ease-in；**禁止弹性过强的 spring**；
循环动画（呼吸、波纹）只用在「系统正在做什么」这类持续状态上；
`prefers-reduced-motion` 下呼吸、波纹、骨架闪光全部停止，转场改为直接切换。

**铁律：不做假动画。** 语音相关动效必须与真实音频状态绑定 —— 波纹随真实音量、播放波形随真实进度。
一旦动效与真实状态脱钩，它就从信息退化成装饰。

---

## 5. 组件规格

| 组件 | Swift 路径 | 规格 |
|---|---|---|
| 说话键 | `Component.talkButtonDiameter` | 72pt 胶囊大按钮，居中于说的房间底部 |
| 呼吸提示 | `Component.breathPeriodSeconds` / `breathScaleAmplitude` | 3s 周期 / 3% 幅度（待按态） |
| 状态灯 | `Component.statusDotDiameter` | 8pt 圆点，卡片右上角；**不单靠颜色**：空心 ○ / 半实 ◐ / 实心 ● |
| 即时反馈徽章 | `Component.badgePopSeconds` / `badgeDwellSeconds` | 200ms 弹性弹出 → 停留 1.5s → 收缩为气泡角标（不消失）；无弹窗、无震动 |
| 触控热区 | `Component.minHitTarget` | ≥ 44×44pt |
| 相邻目标间距 | `Component.minTargetSpacing` | ≥ 8pt |
| 焦点环 | `Component.focusRingWidth` | 强调色 2pt 描边 |
| 图标描边 | `Component.iconStrokeWidth` | 1.5pt 线性描边、圆头端点 |

组件形态（细节见稿子 §2.4）：

- **话术块卡片三段式**：意图（顶部加粗）/ 英文块（`accent`，可点按发音）/ 对比锚点（可折叠）；右上角状态灯，
  已自动化的追加「开会用上过 N 次」。
- **评价卡三段折叠**：目标达成 / 问题清单 / 提高建议，默认只展开第一段，先肯定后改进。
- **加载态**：语料库、历史、每日一读统一用与卡片同形的**闪烁骨架块**，不用转圈 spinner。
  例外是素材提炼 —— 它必须有进度文案（「正在提取讨论点…」）与预期时长，禁止无提示静默等待。

---

## 6. 无障碍（写进令牌的部分）

- 触控热区 ≥ 44×44pt，相邻目标 ≥ 8pt。图标按钮即使视觉更小，热区也不缩水。
- 状态灯形态与颜色同时变化（○ / ◐ / ●）。
- 英文内容均支持点按发音。
- VoiceOver：波形、状态灯、徽章等纯视觉元素必须配 `accessibilityLabel`；徽章 1.5s 自动收起对
  VoiceOver 不可感知，命中时额外发一次无障碍公告。
- 焦点环用强调色 2pt 描边，焦点顺序与阅读顺序一致。
- 对比度：正文 13.68:1、次要文本 6.78:1、三状态色均 ≥ 4.5:1（见第 1 节实测值）。浅色主题的验收随 V1.1 补齐。

---

## 7. 图标（待办，尚未落地）

稿子 §2.5 给出一套**线性描边图标**（1.5pt 描边、圆头端点），共 24 个：
`i-home` `i-drill` `i-library` `i-mic` `i-play` `i-pause` `i-replay` `i-wave` `i-star4` `i-ladder`
`i-search` `i-book` `i-talk` `i-gear` `i-clock` `i-flag` `i-shield` `i-trash` `i-copy` `i-info`
`i-chev-l` `i-chev-d` `i-check` `i-x`。

Tab、场景、状态灯、徽章共用同一套；**不使用 emoji 充当功能图标**。当前 iOS 侧用 SF Symbols 顶替，
描边宽度与圆角与稿子不一致 —— 记为设计债，等图标资产交付后统一替换。

---

## 8. 与现状的差距（已知、未做，别重复发现）

1. **视图一处都没用令牌。** `Shared/FluentWorkUI/` 的 10 个视图全部走系统语义色
   （`.secondary` ×32、`.red` ×5、`Color.blue` ×4、`Color.orange` ×3 …）。
   迁移按**每屏各自的 ticket** 走，不做全量覆盖 —— 每屏还有自己的状态矩阵（稿子 §06/§07）要对。
2. **图标资产未交付**（见第 7 节）。
3. **浅色主题未做**，且 `21_` §2.1 的对比度验收在浅色底上很可能不达标，属 V1.1。
4. **动态字体未接**：令牌给的是 pt 绝对值，`Font.system(size:)` 不随 Dynamic Type 缩放。
   130% 不破版这条**尚未验证**。
5. **订阅页（屏 13）后置**：`21_` §4.8 明确 MVP 期入口隐藏，服务端远程开关，V1.1 一键放出。
