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

### 守卫 A · action 双向名单（`f302454` 落地）

**每个 `XxxAction` case，要么在某个视图的回调里被派发，要么在一个写明理由的豁免名单里。**

- 双向校验：名单里的条目必须仍然存在、仍然没被派发（过期条目也要红）；
- 形状照抄既有守卫：`Tests/FluentWorkCoreTests/Audio/AudioSessionOwnershipGuardTests.swift`
  （仓级检索 + 名单双向 + 变异验证过）；
- 它挡住的正是模块轴那 6 条的成因：**数据层做完了、屏幕上没有入口**。

落地时量出来的三件事（都写进了那份文件头）：

1. **「屏幕层」= `App/` ＋ `Shared/FluentWorkUI/` ＋ `AppRootTabView.swift`** —— 第三个是量出来的：
   底部 tab 栏那个视图住在 `Shared/FluentWorkCore/Navigation/` 里，只扫 `App/` 会把
   `navigation.selectTab` 误判成「没有入口」。**视图在哪个模块里是历史，不是定义。**
2. **只查一层**：嵌套载荷里的 `SpeechSessionEvent` 是传输泵喂给状态机的输入（27 个 case 里
   只有 4 个由屏幕派），「屏幕能不能派它」对它不是对的问题；`WorkspaceSurface` / `AppTab` 是值。
   要盯的那个嵌套事件由守卫 B 点名。
3. **表分三组**，理由的性质不同：中间件派（正常）/ 屏幕未落地（债，随 ④ 变短）/
   **没有任何派发者（死 action，14 条）**。第三组的「没有派发者」本身也有一条判据当场验证。

### 守卫 B · 驱动与视图同一张表（`f302454` 落地）

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

- ~~**导航目的地**~~ —— **已在 ③ 完成**。原来的形状是：
  `AppRoute(entryRoute: "/drill")` 是 `nil`，而
  `Tests/FluentWorkCoreTests/Architecture/LaunchToNavigationEndToEndTests.swift:34` 正在断言这件事；
  `:61-71` 还断言只有 first-wave 四条路由能解析。
  **那两条断言确实是内置的提醒物**：加路由时它们必须跟着改，改不动说明路由没接上 ——
  ③ 就是先改它们、看着它们红，再落实现的（见下方进度表）。
- ~~**⑤-2 话题卡（H1/H2/H3）**~~ —— **数据层与屏幕都已完成**（屏幕见 ④ 一节）。
  **F2 状态灯**：**已核对，它的 store 落点本来就有** —— `PhraseBlock.state` 一路进到
  `CorpusState.items`，丢的是投影那一步（`CorpusRowViewData` 里没有它），所以它不满足
  「读一个永远为空的字段」，而是**反过来的那一类**：数据到位、屏幕上没有。
  **已在 F2 落地时一并做完**（`8bd2808`，投影 + 视图 + 5 条判据）。
- **G2 语音偏好（含 AI 语速）**：仍然成立 —— 语速是合成参数，跨仓，要先定走哪条路。
- ⚠️ **闪测屏（E1/E2/E4）卡在一条不存在的采集链路上** —— ④ 动工时才发现，**这是 §7 这一节
  第一次没能提前看出来的前置条件**：
  - `DrillAction.answerCaptured(asrText:at:)` 要的是**文本**，而客户端今天没有任何东西产出它。
    `ClientASRTranscriber`（`Shared/FluentWorkCore/Services/ClientASRTranscriber.swift`）是一份
    **只有文档注释、从未接线**的协议：`clientASRTranscriber` 在全仓的唯一出现就是它自己注释里的
    `Container.shared.clientASRTranscriber()`；`pcmAudioStream()` 同理零实现。
  - 唯一真实的采集路径是对话房间的 `LiveAudioEngine.startCapture()`，绑在
    `SpeechSessionMiddleware` 的 WSS 会话上。
  - 技术方案（`fluentwork-meta` `32_…iOS App端技术设计文档.md:127`）把 E1–E4 的落点写成
    「**计时 + 异步判定 + 队列调度**」，并且 `:224` 写着「闪测/对话/跟读**共用一次授权**」——
    也就是说「说的话怎么变成文本」被划在了 E1–E4 之外，属音频链路。
  - ⇒ 闪测屏要动，先要有一个决定：复用房间的 WSS ASR、还是上设备端 Apple Speech、
    还是 Volcengine。这条决定的方向会牵到 `SharedAudioSessionOwner` 的租约名册（F6/R1–R10 那一摊）。
    **在它定下来之前，闪测屏保持占位**；守卫 A 的第 ② 组留着那 7 条 `drill.*` 并写明了原因。
- **投影搬迁**（第 2 节）。

---

## 8. 实施顺序（业务逻辑收口后）

1. **投影搬迁 + P1–P4**（零行为变更，可与 UI 并行；先做它，后面每一步才有判据兜底）；
2. **守卫 A + 守卫 B**（两条仓级守卫，各自带变异验证）；
3. **`AppRoute` 补闪测 / 话题卡目的地**（属业务逻辑，可测；顺手改掉那两条断言）；
4. **逐屏落地 UI**，每屏收尾跑真机场景 + 填走查表。

### 进度

| 步 | 状态 |
|---|---|
| ① 投影搬迁 | **✅ 9/9 完成**。`Review`（`4ce2e57`）、`speakingRoom`（`ba281dd`）、`dailyRead`（`79816e5`）、`sessionHistory` + `sessionDetail`（`66b7a78`）、`corpus` + `badgeFeedback`（`be1d22d`）、`settings` + `workbenchHome`（`2ffa112`）。`HostRootView` 里已无 `make*ViewModel` |
| ② 两条守卫 | **✅ 完成**（`f302454`）。守卫 A `ScreenEntryGuardTests`（每个 `AppAction` case 要么在屏幕层被派发、要么在表里写明理由；表分三组：中间件派 64 / 屏幕未落地 18 / **死 action 14**）、守卫 B `ScenarioDriverTableGuardTests`（驱动与视图同一张表）。10 次变异全部咬住 |
| ③ `AppRoute` | **✅ 完成**。`AppRoute` 补 `.drill` / `.topicCards`（`entryRoute` / `init?(entryRoute:)` / `defaultWorkbenchNavigationAction`）；`FeaturePluginCatalog` 补 `/topic-cards`；工作台四张表与 `Module.Kind` 跟着补；`HostRootView` 补两个目的地（占位，与 Tab 2 根**共用同一个视图**）。6 条变异全部咬住 |
| ④ 逐屏 UI | **进行中**。话题建议屏（H1 列表 / H2 来源标注 / H3 打卡草稿 + 86_ M11 忽略）**已落地**：投影 `FluentWorkUI/Topic/TopicProjection.swift` + 视图 `TopicCardsRootView.swift` + Host 接线，10 条判据，守卫 A 的第 ② 组因此从 18 条缩到 **11 条**。闪测屏**卡在采集链路**（见 §7），保持占位 |

③ 之后顺手清掉了 §7 里「F2 状态灯」那条前置条件（`8bd2808`，投影 + 视图 + 5 条判据，变异 6/6），
以及模块轴记的「`AppTab` 注释与代码不一致」（`c3b079b`）。**④ 逐屏的入口条件是齐的**：
闪测与话题卡在 ③ 之后有目的地（flag 打开时工作台上是可点的），投影层在 ① 之后有判据兜底。

### ③ 的红是哪些，以及一条预测错了

改到新预期之后、实现之前，**实际红了四组**（都是断言失败，不是编译失败）：

| 判据 | 红在哪 |
|---|---|
| `appRouteBridgesPluginEntryRoutes` | `/drill`、`/topic-cards` 仍是 `nil` |
| `appRouteBuildsWorkbenchNavigationActions` | `/topic-cards` 拿不到动作；`.drill` 的动作还是 push |
| `pluginCatalogEntryRoutesAlignWithAppRoute` | 目录里的 `Drill` 解析不出来 |
| `WorkbenchHomeProjectionTests` 的两条 | 四处表退回 `.unsupported` / 默认标题；`isAvailable` 还是 `false` |

**预测错了一半，如实记下**：进度表原写「落地时**守卫 A** 与工作台的 `isAvailable` 判据会红」。
实际只有工作台那条红了 —— 守卫 A **不该**红，也不该因为它没红而以为漏了东西：

- 守卫 A 问的是「`AppAction` 的 case 有没有**屏幕派发点**」；
- ③ 只加路由、不加屏幕，所以 `drill.*` / `topic.*` 那 14 条仍然合法地待在
  「屏幕还没落地」那一组里。

两件事被那句话混成了一件：**「有入口」的判据在 `isAvailable` 上，「有屏幕」的判据在守卫 A 上。**
守卫 A 到 ④ 落地闪测/话题卡屏幕时才会缩短。

### ③ 里唯一的产品决定：闪测的入口是**切 Tab**，不是 push 一页

`AppRoute.drill.defaultWorkbenchNavigationAction` 返回 `.selectTab(.flashTest)`。
依据是 09-26 稿 §03：闪测住在**底部 Tab 2**，关键路径审计写的是「闪测｜底部 Tab → 直接开始｜1」。
把同一屏同时做成工作台栈里的一页，它会因来路不同而有两种行为（Tab 根 / 推入页）——
正是 `HostRootView` 在 `sessionDetail` 的「继续练习」上明确拒绝过的形状。
这条决定由 `appRouteBuildsWorkbenchNavigationActions` 钉住（改实现它就红）。
`.topicCards` 则与每日一读同类：`.workbench(.push(.topicCards))`。

### 搬迁过程中查出的缺陷（这就是先搬它的理由）

四件里三件是**真缺陷**，它们在搬迁之前**一条判据都看不到** —— 因为那一层住在 app target，
而 app target 没有测试 target：

| 缺陷 | 后果 | 出处 |
|---|---|---|
| 回顾投影仍读 `payload.refineCards` | D2 的**丢弃与编辑在屏幕上完全不生效** | `4ce2e57` |
| 提示身份 `phraseBlockID ?? "badge"` 会撞 | 一轮里两条只有 badge 的命中拿到**同一个 `ForEach` 身份**（SwiftUI 未定义行为） | `ba281dd` |
| 详情投影只在「有 detail」那条出口传 `errorMessage` | **失败的详情页说不出失败原因**，屏幕退到「检查网络后重试。」 | `66b7a78` |
| 两份投影各自在内部读 `Date()` | 「今天/昨天/9月10日」三档文案**不可重现**，所以一条判据都没有 | `66b7a78` |

另外两处签名在搬迁中被改掉，因为**原来的签名是假的**：

- 设置页的 `appVersion` 原来在投影里读 `Bundle.main` —— 在测试进程里那是**测试 runner 的
  bundle**，也就是「版本号显示得对不对」恰好是最查不了的一件事；现在从签名进来。
- 工作台的投影原来直接读 `store.state`（`bootstrapStatus` / `lastErrorMessage` / `network`），
  签名却写着只依赖 `WorkspaceState` —— 实际依赖四个。三个输入已提到签名上。

还有一处**模块边界**是搬迁带出来的：`FluentWorkUI` 第一次需要命名
`FluentWorkFeatureFlags` 的类型（设置页要画开关列表），依赖已补进 `Package.swift`（无环）。

还查到两处**规则写了两遍**（尚未构成行为分歧，但已在分叉的路上）：

- `DailyReadState.showsSkeleton`（Core）与 `DailyReadViewModel.showsSkeleton`（UI）是同一条规则的
  两份写法，靠 `generating → .loading` 这一条映射撑着 —— 已在 `79816e5` 用判据在**整个相位域**上
  钉住两侧相等；
- **`ReviewState.showsSkeleton` 是一份没人读的死规则**（`ReviewFeature.swift:123`），而
  **回顾页根本没有骨架屏** —— Core 里写着一个屏幕行为，那个屏幕没实现它，没有任何东西在提醒。
  归 **UI 缺口**（④ 逐屏时补，走查清单里加一条「loading 态要有骨架屏」）。

**每一步都按同一个形状做**：先落桩（桩＝搬迁前 Host 里那一行）→ 判据真红 → 实现 → 全绿 →
**逐条变异验证**。搬完 Review 那一份暴露出来的两条经验：
（a）`FluentWorkUI` 本来就依赖 `FluentWorkCore`，**不用动 `Package.swift`**；
（b）判据要**先编辑一张卡再断言**，否则「按稳定键查」与「按内容 id 查」两种写法同值，
判据不咬人 —— 一条不咬人的判据比没有判据更坏。

搬到 5/9 时，同一条教训又出现了三次，都是「判据没咬住」而不是「实现写错」：

1. `isUser` 写死 `true` 也能过 —— fixture 里只有一条**用户**行，「谁说的」没有判别力。
   给 fixture 补一条 AI 回复才转红。（`ba281dd`）
2. `.paused` 映成 `.playing` 也能过 —— 判据只用了 `.playing` 一个相位。
   **只测一个分支的判据会替其余分支签字。** 补成四个相位逐个对应才转红。（`79816e5`）
3. 变异锚点不唯一（`case .failed: phase = .failed` 在两个投影里各有一处）⇒ **变异根本没落地**，
   那一轮「一片绿」不是通过。换唯一锚点重做才转红。（`66b7a78`）

反过来也踩过一次：判据红了要先判断**是实现错还是期望错** —— `66b7a78` 里有两条红是期望写错了
（把「现在」的日子当成了记录的日子），实现是对的。

到 9/9 收口时又加了第四条，这次是**删除范围**而不是判据：搬 `settings` 时我的删除区间把夹在
两个函数之间的 **`workbenchRoot` 计算属性**一起吞了，而 `swift build` **全绿** —— 因为腿 1 只编
SwiftPM 的 target，**`App/` 根本不在里面**；是腿 2 报的 `cannot find 'workbenchRoot' in scope`。
**腿 1 通过不等于能编译 app。** 这条同时也是本文件开头的论点（投影层只有腿 2 看得见）的又一次实证。

---

## 9. 一句话

**UI 里体现的功能 = 数据层（已守）+ 投影层（必须补，且要先搬位置）+ 派生层（已守）
+ 像素层（人眼清单）。** 先做投影搬迁与两条守卫，再动 UI；这四层之外的东西，
如实承认它测不到，不要用一个代理指标去假装测到了。
