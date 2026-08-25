# Bootstrap 与导航导读

**版本**：V1.0  
**日期**：2026-08  
**定位**：说明 `app bootstrap` 做什么、导航 / Route 如何串起来、当前测试覆盖到哪

---

## 一、App Bootstrap 做什么

Bootstrap **不是**「画启动页」，而是 **App 冷启动后的最小就绪流水线**：

1. Host / 调试按钮 `dispatch(.lifecycle(.appLaunched))`
2. Reducer：`bootstrapStatus = .loading`
3. Middleware 调 `BootstrapClientProtocol.loadBootstrap()`
4. 成功 → `bootstrapSucceeded(BootstrapSnapshot)`：写入 Feature Flag、preferredSurface，并做插件投影
5. 失败 → `bootstrapFailed` + `lastErrorMessage`
6. 同一次 `appLaunched` 还会启动 `networkMonitor`（连通性进 `AppState.network`）

当前默认客户端是 `ResolverBackedBootstrapClient`：

```text
TGFeatureFlag Resolver.refresh / snapshot
  → FeatureFlagSnapshotMapper
  → BootstrapSnapshot.featureFlags
  → Store（真源）
  → applyFeatureFlagProjection
       · speakingRoom.isBootstrapReady
       · workspace.availableModules（插件目录按 Flag 过滤）
```

**一句话**：Bootstrap = 拉齐「开关 + 工作台可见模块 + 网络态」的启动接缝；正式 API/票据以后也会挂在这条链上，而不是散落在各个页面。

---

## 二、导航整体：三层概念

### 1. `AppTab` — 底部三个根

工作台｜闪测｜语料库。存在 `AppNavigationState.selectedTab`，每个 Tab 各自一份栈。

### 2. `AppRoute` — 类型化目的地（TGNavigationStack 的 Route）

```swift
enum AppRoute {
  case speakingRoom(sessionID: String?)
  case review(sessionID: String?)
}
```

- `push` / `pop`：改该 Tab 的 `NavigationState.path`
- `present(..., .fullScreenCover)`：改 `presentedRoute`（说的房间 / 回顾用全屏 cover）
- 手势返回：View Binding → `NavigationAction.setPath` / `dismiss` → Reducer（单向数据流）

库：`TGNavigationStack`（`NavigationState` / `NavigationAction` / `navigationReducer` / `TGNavigationStack` View）。  
本仓：`AppNavigationState` + `AppNavigationAction` + `AppRootTabView`。

### 3. `entryRoute` — 插件目录里的字符串路径

`FeaturePluginDescriptor.entryRoute`（如 `"/speaking-room"`）描述「工作台入口要去哪」。  
它与 `AppRoute` 通过桥接对齐（`AppRoute(entryRoute:)` / `AppRoute.entryRoute`），避免目录字符串和枚举漂移。

```text
插件 Catalog.entryRoute  ──map──►  AppRoute  ──dispatch──►  某 Tab 的 NavigationState
                                      ▲
                                      │
                         TGNavigationStack 渲染 path / fullScreenCover
```

**尚未做的**（有意留给 I5）：工作台点击 `availableModules` 自动 `present` 对应 `AppRoute`；当前 Host 用调试按钮直接 `dispatch` navigation action。

---

## 三、在 Host 里怎么用

1. `AppRootTabView(navigation:dispatch:…destination:)` 读 Store 的 navigation，把 Action 派回 Store  
2. 调试区「Present Speaking Room」≈：

```swift
.dispatch(.navigation(.workbench(.present(.speakingRoom(sessionID: nil), style: .fullScreenCover))))
```

3. 切 Tab：` .navigation(.selectTab(.corpus)) `

---

## 四、测试覆盖（分析结论）

| 层级 | 已有 | 缺口（曾） |
|---|---|---|
| Reducer：bootstrap 成功投影 | ✅ `AppReducerTests` | — |
| Middleware：注入 client 成功/失败/防重入 | ✅ `AppBootstrapMiddlewareTests` | — |
| Navigation reducer 单测 | ✅ present / selectTab | — |
| Resolver → 领域 Snapshot | ✅ mapper 单测 | — |
| **启动 → Flag/插件 → 导航 present 串联** | ❌ 曾无 | ✅ 已补 `LaunchToNavigationEndToEndTests` |
| UI / XCUITest 真机手势 | ❌ | 按 docs/02：当前不优先 |

说明：本仓「端到端」指 **Store + Middleware + 隔离 DI 容器的集成测试**（见 `LaunchToNavigationEndToEndTests`），不是 XCUITest。真机导航手势仍依赖后续 Host QA。并行测试勿共用 `Container.shared`（易互相 `reset`/覆盖）。
