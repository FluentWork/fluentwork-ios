# Bootstrap 设计原理说明

**版本**：V1  
**日期**：2026-09  
**适用范围**：`fluentwork-ios` 当前 `App bootstrap` 实现  

---

## 1. 先说结论

当前 iOS 的 bootstrap 设计，核心目标不是“启动时顺手拉点数据”，而是把 **App 冷启动后必须先收敛的全局前置条件** 集中到一条受控流水线里。

这条流水线当前负责三件事：

1. 获取远端 feature flag，并投影到 Store。
2. 确保当前会话具备可用身份信息（当前是 guest token / auth info）。
3. 决定启动后工作台优先落到哪个 surface（`preferredSurface`）。

它刻意**不**直接做页面跳转、也不在 UI 层里写启动判断，更不把各种首屏策略散落在各 Feature 里。

---

## 2. 当前链路长什么样

代码入口分成四层：

1. `appBootstrapMiddleware`
   - 文件：`Shared/FluentWorkCore/Architecture/Middleware/AppBootstrapMiddleware.swift`
   - 责任：监听 `.lifecycle(.appLaunched)`，触发 bootstrap 异步任务。

2. `BootstrapClientProtocol`
   - 文件：`Shared/FluentWorkCore/Dependencies/AppDependencies.swift`
   - 责任：定义“如何拿到 bootstrap 结果”。

3. `ResolverBackedBootstrapClient`
   - 文件：`Shared/FluentWorkCore/Dependencies/AppDependencies.swift`
   - 责任：真正去拉 feature flags、确保 guest token，并组装 `BootstrapResult`。

4. `AppReducer`
   - 文件：`Shared/FluentWorkCore/Architecture/AppReducer.swift`
   - 责任：把 `BootstrapResult` 投影进全局状态。

完整时序：

```text
appLaunched
  -> appBootstrapMiddleware
  -> bootstrapClient.loadBootstrap()
      -> ensureGuestToken()
      -> resolver.refresh()
      -> resolver.snapshot(...)
      -> preferredSurfaceProvider()
      -> BootstrapResult(snapshot, authInfo)
  -> .lifecycle(.bootstrapSucceeded(...))
  -> AppReducer 投影到 AppState
      -> bootstrapStatus = .ready
      -> featureFlags.snapshot = ...
      -> workspace.activeSurface = snapshot.preferredSurface
      -> auth = guest / registered
      -> applyFeatureFlagProjection(...)
```

---

## 3. 为什么要拆成现在这样

### 3.1 Middleware 只负责触发，不负责解释业务

`appBootstrapMiddleware` 的职责非常窄：

1. 只在 `appLaunched` 时触发。
2. 调用 `bootstrapClient.loadBootstrap()`。
3. 成功发 `bootstrapSucceeded`，失败发 `bootstrapFailed`。

它不自己拼装 Store 状态，也不判断 Feature 开关该怎么影响模块可见性。

原因很直接：  
如果 middleware 同时负责“拉数据 + 解释数据 + 写状态”，测试会非常脆，错误边界也会混在一起。

### 3.2 BootstrapClient 只负责产出结果，不直接碰 Store

`ResolverBackedBootstrapClient` 返回的是：

```swift
BootstrapResult(snapshot: BootstrapSnapshot, authInfo: AuthInfo?)
```

而不是直接拿到 Store 去写。

这样做的原因：

1. 让 bootstrap 成为一个可替换的依赖。
2. 测试时可以换成 `StaticBootstrapClient` 或更轻量的假实现。
3. 网络、鉴权、feature flag 这些外部依赖可以在 client 层被隔离。

这也是为什么我们这次能把一组 `.disabled` 测试恢复为正式测试：  
测试不用再依赖真实 backend，只要替换 bootstrap client 即可。

### 3.3 Reducer 才是全局状态的唯一解释层

真正把 bootstrap 结果变成全局状态的是 `AppReducer`：

1. `bootstrapStatus`
2. `workspace.activeSurface`
3. `featureFlags.snapshot`
4. `auth`
5. `workspace.availableModules` 等派生状态

这样做的原因是：  
**Store 才是状态真源，bootstrap client 只是输入源。**

如果 client 直接写状态，或者 UI 读完结果自己 patch 状态，后面就很难保证行为一致。

### 3.4 `preferredSurfaceProvider` 必须独立出来

这里最容易困惑。

`preferredSurface` 不是远端 flag 的一部分，也不是导航层直接决定的结果。  
它是一个“启动策略输入”。

当前我们把它拆成：

```swift
var preferredSurfaceProvider: Factory<@Sendable () -> WorkspaceSurface>
```

原因：

1. 生产默认值非常简单：`.speakingRoom`
2. Debug 环境可以覆盖：
   - launch arguments
   - UserDefaults
   - 测试注入
3. bootstrap client 每次加载时再读取 provider，保证策略是“运行时可替换”的

这比把 `preferredSurface` 写死在 `ResolverBackedBootstrapClient` 里更好，因为它避免了：

1. 把调试逻辑混进远端解析逻辑
2. 为了改启动入口去改网络 client
3. 测试时不得不接真实 resolver / session API

---

## 4. 为什么测试里要用 StaticBootstrapClient / SurfaceOnlyBootstrapClient

这次修复里最关键的一点，就是把测试从“看似是启动测试，实际偷偷依赖网络”改成“真正隔离的状态链路测试”。

### 4.1 不该在这类测试里验证什么

以下内容不应该混进 launch / bootstrap 状态测试：

1. 本地 backend 是否在线
2. token 接口是否可达
3. feature flag 远端服务是否正常
4. 当前机器的 `LOCAL_HOST` / `AppEnvironment` 是否配置正确

这些属于集成环境问题，不属于 Store/bootstrap 状态投影问题。

### 4.2 这类测试真正要验证的内容

`LaunchToNavigationEndToEndTests`、`BootstrapSurfaceProviderTests` 这类测试应聚焦：

1. `appLaunched` 是否触发 bootstrap
2. bootstrap 结果是否正确进入 Store
3. `preferredSurfaceProvider` 是否在加载时被调用
4. debug override 是否真的影响 bootstrap 结果
5. 导航和状态投影是否一致

因此：

1. `LaunchToNavigationEndToEndTests` 使用 `StaticBootstrapClient`
2. `BootstrapSurfaceProviderTests` 使用 `SurfaceOnlyBootstrapClient`

这样测试目标是清晰的，CI 也不会依赖本地环境。

---

## 5. 这套设计和 `AppEnvironment` 的关系

这也是一个常见混淆点。

`AppEnvironment` 解决的是：

1. API base URL 指向哪里
2. WSS base URL 指向哪里
3. 当前是在 development / local / production 哪种宿主环境

bootstrap 解决的是：

1. 启动时需要的 feature flag / auth / surface 策略
2. 这些结果如何投影进全局 Store

所以两者关系是：

```text
AppEnvironment = 连接到哪个后端
Bootstrap = 连上后，启动时先把哪些全局前置状态收敛进 Store
```

不要把它们混成一件事。

如果某个测试只是验证 bootstrap 状态流，就不应该要求 `AppEnvironment` 真能打到某个本地服务。

---

## 6. Debug override 为什么设计成改 DI，而不是直接改 Store

`DebugBootstrapConfiguration` 当前通过：

1. `Container.shared.preferredSurfaceProvider.register { ... }`
2. `Container.shared.preferredSurfaceProvider.reset()`

来影响 bootstrap。

这样做的意义是：

1. Debug 行为和生产行为走同一条 bootstrap 链
2. 不会出现“调试环境绕过 bootstrap，直接偷偷改 Store”的分叉逻辑
3. 测试可以和真实运行时共享同一个扩展点

也就是说，debug override 改的是 **输入源**，不是 **结果状态**。

这是更稳定的设计。

---

## 7. 当前设计的边界

这套设计不是万能入口，它有明确边界。

### 适合放进 bootstrap 的

1. 冷启动必须先拿到的全局配置
2. 全局身份前置条件
3. 会影响工作台结构或入口选择的启动快照

### 不适合放进 bootstrap 的

1. 某个 Feature 页面进入后才需要的数据
2. 高频轮询数据
3. 用户交互驱动的即时请求
4. 纯 UI 层临时态

如果什么都往 bootstrap 塞，启动时间会变长，失败面也会扩大。

---

## 8. 后续新增需求时怎么扩

### 场景 A：新增启动时必须下发的全局信息

例如：

1. 账号实验桶
2. 首屏模块排序
3. 启动阶段的全局能力开关

做法：

1. 扩 `BootstrapSnapshot`
2. 在 `ResolverBackedBootstrapClient.loadBootstrap()` 里组装
3. 在 `AppReducer.bootstrapSucceeded` 里投影到 Store
4. 补 reducer / middleware / store-level tests

### 场景 B：新增调试入口策略

例如要支持：

1. `--daily-read-first`
2. 调试菜单持久化到其他 key

做法：

1. 只扩 `preferredSurfaceProvider` 的生成逻辑
2. 不要改 `ResolverBackedBootstrapClient` 的核心网络逻辑
3. 用 `BootstrapSurfaceProviderTests` 补覆盖

### 场景 C：新增真实后端联调

做法：

1. 放到专门的联调 runbook / smoke 脚本
2. 不要回灌到纯 Store/bootstrap 单测里

---

## 9. 当前相关测试的分工

### `AppBootstrapMiddlewareTests`

验证：

1. middleware 是否触发 bootstrap
2. 成功/失败路径是否正确 dispatch
3. 防重入是否成立

### `LaunchToNavigationEndToEndTests`

验证：

1. launch 后 bootstrap 是否完成
2. bootstrap 结果是否正确投影到导航和 workspace 状态
3. 这类测试应保持 hermetic，不依赖网络

### `BootstrapSurfaceProviderTests`

验证：

1. `preferredSurfaceProvider` 默认值和 override 行为
2. debug 配置是否真的影响 bootstrap 结果
3. provider 是否按 bootstrap 调用时机被求值

---

## 10. 一句话原则

当前 bootstrap 设计可以概括为一句话：

**把启动阶段必须统一收敛的输入集中在 `BootstrapClient`，把结果解释统一留在 Reducer，把可变启动策略通过 DI provider 注入，而不是把环境、网络、导航和调试逻辑揉成一团。**
