# I7 review 视图集成踩坑说明

## 背景

`I7` 需要把第一波的 review 骨架页升级为可消费 backend `B9` full review model 的正式页面。

这次实现过程中，最容易犯错的不是接口解码，而是 **UI 模块、Core 状态、Host 接线三层边界**。

## 这次踩到的坑

### 1. 不要让 `FluentWorkUI` 直接依赖 `FluentWorkCore`

错误方向：

1. 在 `FluentWorkUI/ReviewRootView` 里直接接收 `ReviewState`
2. 在 `FluentWorkUI` 中直接派发 `ReviewAction`
3. 让展示层知道 TGReduxKit 的 store / action 细节

这会带来两个问题：

1. `UI` 层和 `Core` 层耦合，破坏当前仓库“Core 管状态与副作用，UI 保持展示组件”的结构
2. 后续一旦 review 状态机调整，`FluentWorkUI` 会被迫跟着改，模块边界失效

正确方向：

1. `FluentWorkUI` 只接收纯展示模型
2. `HostRootView` 或 `Core` 外层容器负责把 `ReviewState` 投影成 UI props
3. `ReviewAction` 只在 `Core` / Host 层派发

当前落点：

1. `Shared/FluentWorkUI/Review/ReviewRootView.swift`
   - 只接 `ReviewViewModel`
   - 只暴露 `onAppear` / `onRetry`
2. `App/FluentWorkHost/HostRootView.swift`
   - 负责 `ReviewState -> ReviewViewModel` 映射
   - 负责派发 `.review(.appear(...))` / `.review(.loadRequested(...))`

### 2. 不要为了图省事，把展示层做成第二个 reducer 容器

错误方向：

1. 在 view 内部直接拼装复杂状态逻辑
2. 在 view 内自行推断 `pending / ready / failed`
3. 在 UI 层做 review payload 的语义归并

正确方向：

1. `ReviewFeature` 负责状态归并
2. `reviewMiddleware` 负责异步拉取
3. `ReviewRootView` 只消费已经整理好的展示数据

当前状态职责：

1. `Shared/FluentWorkCore/Architecture/Features/ReviewFeature.swift`
   - `ReviewState`
   - `ReviewAction`
   - `reviewReducer`
2. `Shared/FluentWorkCore/Architecture/Middleware/AppBootstrapMiddleware.swift`
   - `reviewMiddleware`

### 3. 不要在并发测试里复用 `Container.shared`

错误方向：

1. 在 middleware 测试里直接 `Container.shared.reset()`
2. 测试里覆盖全局依赖，再假设别的测试不会并发碰它

这会导致：

1. 单测单跑通过
2. `swift test` 全量并发时偶发失败
3. 表现为 middleware 没有按预期拿到 stub 依赖，出现超时或状态未推进

正确方向：

1. 为每个 middleware 测试创建局部 `Container()`
2. 只给当前 store 注入这个局部容器

参考做法：

1. `Tests/FluentWorkCoreTests/Architecture/ReviewFeatureTests.swift`
2. `Tests/FluentWorkCoreTests/Architecture/AppBootstrapMiddlewareTests.swift`
3. `Tests/FluentWorkCoreTests/Architecture/LaunchToNavigationEndToEndTests.swift`

### 4. 不要用拍脑袋 `sleep` 断言异步状态

错误方向：

1. `Task.sleep(50ms)` 后直接断言 `.ready`
2. 认为单机本地快，就代表 CI / 全量并发也稳定

问题：

1. 单跑可能通过
2. 全量测试时容易抖

正确方向：

1. 用带超时的条件等待
2. 明确等到目标状态出现，再断言 payload

## I7 的正确结构

### 1. Networking

`FluentWorkNetworking` 负责：

1. `ReviewPollResponse`
2. `ReviewReadyPayload`
3. review full model 的 DTO 解码

### 2. Core

`FluentWorkCore` 负责：

1. `ReviewState / ReviewAction / reviewReducer`
2. `reviewMiddleware`
3. 把 review 纳入 `AppState` / `AppAction`

### 3. Host

`HostRootView` 负责：

1. 从 `store.state.review` 取状态
2. 映射成 `ReviewViewModel`
3. 连接 `onAppear / onRetry`

### 4. UI

`FluentWorkUI` 负责：

1. 渲染 skeleton / error / ready
2. 展示 `overview / transcript / dual_column / refine_cards`
3. 不直接依赖 `ReviewState`、`ReviewAction`、`Store`

## 本次测试覆盖

### 已补

1. `ReviewFeatureTests`
   - reducer 的 `pending -> ready -> failed`
   - middleware 拉取 full review payload
2. `SessionAPIClientTests`
   - full review payload 解码

### 当前没补

1. `ReviewRootView` 的独立 UI 快照测试
2. `HostRootView` 中 review 路由的端到端导航断言

这两项可作为后续视觉/导航稳定性增强项，但不阻塞 `I7` 当前收口。

## 后续实现纪律

后续如果继续做 `I8 / I9 / I10`，遵守下面三条：

1. **先定状态边界，再接 View**
2. **UI 只吃 view model，不直接吃 Core 状态机**
3. **middleware 测试一律优先用隔离容器**
