# 会话列表：接通读路径，暂不进入

**日期**：2026-09-12
**状态**：代码与测试已齐。列表**能列出真实数据**；**点进去是下一步**（`79_` 本票 · 2），本片刻意不做。
**对应**：meta `79_` **本票 · 1**（会话列表）

## 1. 为什么是这个形状

`79_` 把「会话列表与连续性」拆成三片。本片是**第一片：列表本身** —— 数据源、分页、空态、失败态、入口。

拆片的理由不是工程量，是**第 2 片会让第 1 片的形状反过来**：进入旧房间要读 `SessionDetail.utterances`，而那一场**服务端恢复不了**（`77_` P1-15 已核实）。所以「进入」是**只读重现 + 另开一场新的**，不是续接。先把列表做出来、把这件事说清楚，比一次性做一个点进去会清空的入口要好。

## 2. 一个刻意的缺失：行**不可点**

这是本片最需要解释的决定。

今天把行点亮，唯一能去的地方是 speaking room，而 speaking room 会**开一场全新的服务端会话**。用户点「昨天那场」，落进一个空房间 —— 那正是这张票要消除的现象本身（「结束会话后再次进入，之前的对话内容都没了」）。

所以行**不做成可点的**，列表底部用一句普通话说明现状，而不是留一行看起来能点、点了没反应、或者更糟——点了清空的东西。进入的那一下，和第 2 片一起上。

## 3. 进房间的入口（本片的入口是**进列表**）

工作台模块 `SessionHistory`，`entryRoute: "/sessions"`，与 `review` / `dailyRead` 同级 —— 是 route，不是 tab。

**它带一个 flag `AppFeatureFlag.sessionHistory`，且进 `firstWave`（默认开）。** 一个默认开的 flag 看起来是多余的，两个理由让它值得：

1. 列表**带着已知缺口上线**（§5：没有可读标题）。settings tab 是刚建的，它存在的意义就是「真机上出问题能关掉」——比线上出问题再回滚便宜。
2. 工作台上每个模块都由 `FeaturePluginDescriptor` 描述、按 flag 过滤（`AppReducer.swift:178`）。把这一条做成例外，等于在工作台上开一个「不受 flag 管」的先例。

代价是四处钉住模块清单的测试要一起改（§6 已列），这是**故意的**：工作台的组成变了，测试就该红一次。

## 4. 实现

### 4.1 `sessionHistoryMiddleware` 比 `corpusMiddleware` **薄得多**，这是对的

corpus 有 cache、outbox、tombstone、merge rebuild。会话列表**一个都没有**，因为这里没有可离线编辑的东西可对账：会话活在 `practice_sessions`，客户端复制一份立刻产生两处真相（`79_` §设计 1）。中间件只做三件事：`.appear` / `.refreshRequested` 取第一页，`.loadMoreRequested` 带 cursor 取下一页。

### 4.2 那个 flag 必须在 `next(action)` **之前**读

```swift
let isFirstAppear = !store.state.sessionHistory.didRequestInitialLoad
let base = next(action)
guard isFirstAppear else { return base }
```

reducer 在应用 `.appear` 时**就会**把 `didRequestInitialLoad` 翻成 true。所以放在 `next` 之后读，它永远是 true，`isFirstAppear` 永远是 false —— **列表一次都不会加载**，屏幕上是一个永不结束的 spinner。这不是「多了一次请求」，是功能整个死掉。红验证就是这一条（§6）。

顺带：这是 middleware 复制 reducer 的守卫。**必须复制**，因为 middleware 跑在 reducer 外面；而 `.loadMoreRequested` 那一段（`!isLoadingMore` + cursor 非空）是同一个理由的第二次。

### 4.3 `errorMessage` 是新增的一格状态

原 reducer 在 `.loadFailed` 且列表非空时**把 message 丢掉了**：只有 spinner 停下，没有任何东西说「这一页失败了」。用户的下一个动作——再点一次——是猜的。

所以 `SessionHistoryState` 多一格 `errorMessage`：任何失败都写进去，任何**新请求开始**时清掉。`.loadFailed` 仍然只在 `items.isEmpty` 时接管屏幕（这条没变，也不该变）；多出来的只是「失败不是静默的」。

### 4.4 `.refreshRequested` 在空屏时补一个 loading 相位

`.appear` 有 `didRequestInitialLoad` 守卫，**失败之后它不会再触发**。于是「失败页上的重试按钮」走的是 `.refreshRequested`——如果它不改相位，重试按钮看起来什么也没发生，直到响应回来。这就是 §4.3 同一类问题的另一半：**只有列表非空时，refresh 才该保持内容不动**。

### 4.5 格式化放在 core，不放 view

`FluentWorkUI` 至今**没有任何 `DateFormatter`**，本片维持这一点。`SessionHistoryFormatting` 在 core，纯函数，三个入口：`duration` / `startedAt` / `status`。

- `startedAt` 用 `calendar.component` 读时分，**不走 `DateFormatter`** —— 格式串是中文字面量，locale 本来就得强制，而 `ISO8601DateFormatter` 在隔壁 `SessionHistoryJSON` 已经制造过一次 Swift 6 `Sendable` 问题。
- 今天/昨天是**日历日**，不是「24 小时以内」。23:50 的会话，00:30 打开 App 应该是「昨天」，不是「今天」。
- `status` 遇到不认识的值**原样透传**，不折叠成「未知」。这个词表是后端的，已经长过一次；在一行没有任何别的信息的记录上，原始值至少能把它和邻行区分开。
- 宿主把 `now` **读一次**传给所有行：三十行各自调 `Date()` 会在午夜前后对「今天」给出不一致的答案。

## 5. 已知缺口（**不是**没做完）

1. **列表项没有可读标题。** 契约只有 `session_id / scene_type / status / started_at / duration_sec / material_id`，一个人靠「2 分 34 秒、今天 14:32」选不出会话。所以行**只能**以时间和时长开头。标题的正主是 A1 提炼的主题（`80_`），落地的位置是：后端契约 → `SessionHistoryItem` → `SessionHistoryRowViewData` → 行 ——**四处一起改**，注释里已写明。
2. **行不可点**（§2），与第 2 片一起上。

## 6. 红验证与门禁

| 改回错误写法 | 变红的测试 |
|---|---|
| `isFirstAppear` 放到 `next(action)` 之后读 | `aSecondAppearNeitherRefetchesNorDiscardsPages`（超时：列表根本没加载）|
| `appending ? items + page.items : page.items` → `page.items` | `aSecondPageAppends`（`["c"] != ["a","b","c"]`）+ 两条中间件测试 |
| 删掉 refresh 的 `if items.isEmpty { phase = .loading }` | `refreshShowsTheSpinnerWhenThereIsNothingToKeep` |
| 今天/昨天改成 24 小时间隔 | `todayAndYesterdayAreCalendarDaysNotTwentyFourHours` |

```
swift test                                    # 506 passed  (495 + 11)
xcodebuild -scheme FluentWorkHost -configuration Debug \
  -destination 'generic/platform=iOS' build   # BUILD SUCCEEDED
```

同时被改红的既有测试（工作台组成变了，**应该红**）：
`bootstrapSuccessUpdatesGlobalStateAndFeatureScopes`、
`appLaunchMiddlewareUsesInjectedBootstrapClient`、
`launchBootstrapsFlagsThenPresentsSpeakingRoom`、
`pluginCatalogEntryRoutesAlignWithAppRoute`、
`featureFlagsCanDisableSpeakingRoomViaLocalOverride`。

## 7. 本片**不做**

| | 归属 |
|---|---|
| 点进旧房间、重现 `utterances` | `79_` 本票 · 2 |
| 明确的新会话入口（不是「进房间」的副作用） | `79_` 本票 · 3 |
| 列表标题字段 | 后端契约变更；正主是 A1（`80_`）|
| 「AI 记得上一场」 | `77_` **P0-9**（另一件事，`79_` §约束 2 已要求分开报）|
| 转录的本地缓存 | 不做 —— 服务端是唯一真相 |

> 本片交付的是**一条接通的读路径**：真数据、真分页、真空态、真失败态。
> 它**不**交付「回到昨天那场」—— 那需要服务端能恢复一场会话，而它不能（`77_` P1-15）。
> 把这两件事混着说，就是 `79_` 存在的那个误会本身。
