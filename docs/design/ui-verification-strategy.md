# UI 功能部分的验证方案（UI 开发前置约定）

> **状态：前置约定，暂不实施。** 本文只回答一个问题 —— **UI 里体现的功能，准备怎么测** ——
> 并把它拆成可判否的层与可执行的清单。**实施时机：业务逻辑收口之后**（当前队列见文末附录）。
> 本文自己也要能被核对，所以每条结论都带 `file:line`。

---

## 0. 先把问题问准

「UI 里体现的功能」不是一个层，是四个。分不清它们，讨论就会在「UI 测不了」和
「UI 也能测」之间来回打滑。

| # | 层 | 代码在哪 | 今天能不能机器判 |
|---|---|---|---|
| 1 | **数据层**：reducer / 中间件 / 纯状态机 | `Shared/FluentWorkCore` | ✅ 已有的 **776** 条判据（门禁腿 1） |
| 2 | **投影层**：`state → ViewModel` | **`App/FluentWorkHost/HostRootView.swift:394-755`（9 个 `make*ViewModel`）** | ❌ **一条都没有** |
| 3 | **派生层**：`ViewModel` 内部算出的标题 / 可用性 / 意图 | `Shared/FluentWorkUI/*` | ✅ 有先例：`Tests/FluentWorkCoreTests/UI/SpeakingRoomViewTests.swift` |
| 4 | **像素层**：`body`、布局、动效、可用性 | `Shared/FluentWorkUI/*View.swift` | ❌ 不可机器判 |

**第 2 层是唯一的空白，而它恰好是「UI 里体现的功能」里最该被守住的那一半。**

### 为什么它现在守不住 —— 一段可以复现的推理

`App/FluentWorkHost/HostRootView.swift:476`：

```swift
let refineCards = state.payload?.refineCards.map {
    ReviewRefineCardRow(
        id: $0.id, …, isAccepting: …, isAccepted: …
    )
} ?? []
```

D2 刚刚把「哪几张卡该被显示」从 `payload.refineCards` 搬到了 `state.visibleRefineCards`
（丢弃 / 编辑都会影响它）。**如果投影还读 `payload.refineCards`，丢弃与编辑在屏幕上都不生效** ——
而 776 条判据一条都看不到，原因是结构性的：

- 那 9 个 `make*ViewModel` 是 **`private`**；
- 它们在 **app target** 里，而 `project.yml` 只声明了一个 target：`FluentWorkHost`，
  `type: application`（`project.yml:25-26`）—— **app target 没有测试 target**；
- 门禁腿 2 对 app target 的验证**到「能编译」为止**（`Scripts/gate.sh:22-42` 是
  `xcodebuild … build` + 数 `error:`）。

⇒ **「数据层做完了、屏幕上看不见」这一类缺陷，今天在结构上无法被发现。** 这不是疏漏，
是分层的结果；要改的也是分层。

---

## 1. 「功能存在」的定义（可判形式）

`fluentwork-meta/docs/*/问题总清单-PRD模块轴.md` 的结论：那 13 条 ❌ 里有 **6 条是「后端完整、
客户端是零或占位」**，成因是**判据的选择掩盖了它** —— 测试测的是服务端那一半。

它给的修正是：**问「这个功能在真机上有没有一个入口」，而不是问「代码写完了没有」。**

把这句话变成可判的形式 —— 一个能力算「存在」，必须**三条同时成立**：

1. 屏幕上有一个**控件**；
2. 该控件的回调**派出**对应 action；
3. 该 action 在 store 里**能改变状态**（有判据）。

第 3 条今天已经在守。**第 1、2 条没有任何东西在守**，而它们正是「入口」的全部。

---

## 2. UI 开发的第一件事：把投影搬到能被判据碰到的地方

顺序上这不是「先写 UI 再补测试」，而是 **位置决定可测性**：

- `makeXxxViewModel(from:)` 从 `HostRootView` 搬进 `Shared/FluentWorkUI/<Feature>/`，
  做成纯函数（`ViewModels.swift` 里的 `ReviewViewModel.make(from:)` 之类）；
- Host 只留一行接线：`model: ReviewViewModel.make(from: store.state.review)`。

这条搬迁**零行为变更**（同一份映射换位置），所以可以**先做、先测，再动 UI**。
`@testable import FluentWorkUI` 已经在用（`SpeakingRoomViewTests.swift:3`），不需要新 target。

### 判据形状（全部是纯函数判据，毫秒级、CI 可跑）

| # | 判据 | 挡住什么 |
|---|---|---|
| P1 | **每个 `make(from:)` 至少一条判据**，且要覆盖四种态：空 / 加载中 / 有数据 / 失败 | 「只做了 happy path」 |
| P2 | **state 里每个可见维度都必须有人在读**。例：`visibleRefineCards` 里 `isEdited == true` 的卡，投影出的 `row.isEdited` 必须是 true；**行数只等于可见卡数** | 「字段进了 store，屏幕不读它」——D2 那类 |
| P3 | **投影读的每个字段都必须在 store 里存在且有写者** | 「读一个永远为空的字段」 |
| P4 | **破坏性操作可撤回**：`discardedRefineCardIDs` 非空与非空后清空，投影结果要能对称回去 | 撤回按钮的可用性靠猜 |

P2 的断言必须落在**投影后**的值上，不是 `state` 上 —— 否则它只是状态的回声，
实现把 `payload.refineCards` 换成 `visibleRefineCards` 它也不会红。

---

## 3. 两条守卫：把「入口」变成机器能判的

### 守卫 A · action 双向名单

**每个 `XxxAction` case，要么在某个视图的回调里被派发，要么在一个写明理由的豁免名单里。**

- 双向校验：名单里的条目必须仍然存在、仍然没被派发（过期条目也要红）；
- 形状照抄既有守卫：`Tests/FluentWorkCoreTests/Audio/AudioSessionOwnershipGuardTests.swift`
  （仓级检索 + 名单双向 + 变异验证过）；
- 它挡住的正是模块轴那 6 条的成因：**数据层做完了、屏幕上没有入口**。

### 守卫 B · 驱动与视图同一张表

`Debug/DeviceScenarioDriver.swift` 是今天「自动点屏幕」的替代（仅 DEBUG、由 `FW_SCENARIO` 开，
照视图派**同样的 action**）。它的行动序列必须与视图的可点路径**出自同一张表**。

这条有真实代价的教训：驱动第 ③ 步曾经派 `.manualSpeechBegin`（「开始说话」），
而**起会话的是 `.sessionStartTap`**（`HostRootView.restartOrStartSpeakingSession()`）——
于是驱动永远停在 `.idle`，而它把这件事报成「30 秒内没有进入采集」。
**判据在指责被测对象，错的是派 action 的人。** 守卫 B 让那张表只有一份。

---

## 4. 跑在哪、留下什么

| 时机 | 跑什么 | 谁 | 证据留哪 |
|---|---|---|---|
| 每次提交 | 投影判据（P1–P4）+ 守卫 A/B —— 都在腿 1 | 机器 | `./Scripts/gate.sh` → `GATE PASSED` |
| 每次提交 | app target 能编译（腿 2，**不含行为**） | 机器 | 同上（`error:` 计数 0） |
| UI 票收尾 | 真机场景：`SCENARIO=… ./Scripts/smoke-device.sh` | 机器 + 真机 | `.tmp/smoke-device/console.log` 的 `[Scenario] verdict=` |
| UI 票收尾 | 人眼走查表（第 5 节） | 人 | `docs/design/ui-walkthrough/<ticket>.md` |
| 手势 / 音频 / 眼镜 | 可证伪程序（先例：`docs/devnotes/2026-09-30-reconnect-verification.md`） | 人 + 真机 | 同上 |

**没有 XCUITest，本方案也不假设它存在。** `project.yml` 里没有 UI 测试 target；今天没有任何
「点屏幕」的自动化。引入 XCUITest 是一笔**独立决定**（它带来一整套新的不稳定面与设备依赖），
不该被顺手塞进某个 UI 票里。

---

## 5. 人眼那一层：写死成清单，不靠「看一眼」

像素、间距、暗色、动效、可用性**确实测不了**。可做的最低限度是把「看一眼」写成清单，
每个 UI 票收尾填一次并留档，**四类各一遍**：

1. **与 09-26 稿逐项对照**（`docs/design/2026-09-26-prd-v16-ux/`）：布局 / 文案 / 图标 / 状态色；
2. **四种状态各一遍**：空 / 加载 / 有数据 / 失败 —— 最容易只做 happy path 的地方；
3. **动态字体放大两档 + 深/浅色各一遍**；
4. **破坏性操作可撤回**（D2 的丢弃正是这一类）。

清单存 `docs/design/ui-walkthrough/<ticket>.md`，与评测/回顾产出的口径一致：**结论要能复核**。

---

## 6. 反模式（本仓**已经踩过**的，列出来防复发）

1. **「测试测的是服务端那一半」** —— 模块轴 6 条 ❌。判据要问「真机上有入口吗」。
2. **「判据守错了对象」** —— 驱动派错 action，却报「没进入采集」。
3. **「代理指标冒充事实」** —— `AudioSessionSnapshot.looksActive`（采样率非 0）曾被当作
   「会话活着」，而真机反证就在我们自己的日志里：**没人认领过的会话也报 48000**。
   名字最后改成了 `reportsASampleRate`。**UI 侧的同类**：用「有这个控件」代替「控件能用」。
4. **「先绿不算先红」** —— 新判据第一次跑就是绿时，必须补**变异验证**（本会话 D2 + 闪测共 11 次）。
   投影判据尤其容易写成状态的回声。
5. **「别读实现的形状」** —— 按可见结果断言，不按内部解析；D1 那条跨仓契约就是这么钉的
   （`TestBuildRefineCardsView_KeepsTheBlockOrder` 按**位置**断言）。

---

## 7. 前置条件（属业务逻辑，但 UI 落地前必须先有）

- **导航目的地**：`AppRoute(entryRoute: "/drill")` **今天是 `nil`**，而
  `Tests/FluentWorkCoreTests/Architecture/LaunchToNavigationEndToEndTests.swift:34` 正在断言这件事；
  `:61-71` 还断言只有 first-wave 四条路由能解析。闪测屏与话题卡落地前，
  `AppRoute` + `FeaturePluginCatalog` 要先能解析它们 —— 否则就是「有屏幕、没入口」。
  **那条断言恰好是内置的提醒物**：加路由时它必须跟着改，改不动说明路由没接上。
- **⑤-2 话题卡（H1/H2/H3）**、**F2 状态灯 / G2 语音偏好**：字段要在 store 里有落点，
  否则投影 P3（读一个永远为空的字段）当场就会红 —— 这是好事，它把顺序逼对了。
- **投影搬迁**（第 2 节）。

---

## 8. 实施顺序（业务逻辑收口后）

1. **投影搬迁 + P1–P4**（零行为变更，可与 UI 并行；先做它，后面每一步才有判据兜底）；
2. **守卫 A + 守卫 B**（两条仓级守卫，各自带变异验证）；
3. **`AppRoute` 补闪测 / 话题卡目的地**（属业务逻辑，可测；顺手改掉那两条断言）；
4. **逐屏落地 UI**，每屏收尾跑真机场景 + 填走查表。

---

## 9. 一句话

**UI 里体现的功能 = 数据层（已守）+ 投影层（必须补，且要先搬位置）+ 派生层（已守）
+ 像素层（人眼清单）。** 先做投影搬迁与两条守卫，再动 UI；这四层之外的东西，
如实承认它测不到，不要用一个代理指标去假装测到了。
