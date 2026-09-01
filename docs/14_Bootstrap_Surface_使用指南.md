# Bootstrap Surface 使用指南

**版本**：V2  
**日期**：2026-09  
**适用范围**：`fluentwork-ios` 当前 bootstrap 实现

---

## 1. 当前口径

当前 iOS 仓已经没有旧版 `BootstrapSurfaceProviderProtocol -> BootstrapSurface?` 这套实现。

现在的实际方案是：

1. 启动由 `appBootstrapMiddleware` 触发
2. `BootstrapClientProtocol` 返回 `BootstrapResult`
3. `BootstrapResult.snapshot.preferredSurface` 决定启动后的工作台入口 surface
4. `preferredSurfaceProvider` 通过 DI 注入，允许 production/debug/test 使用不同策略

所以这里说的 “Bootstrap Surface”，当前准确含义是：

**bootstrap 过程中决定 `WorkspaceSurface` 初始值的策略与用法。**

不是单独的一层欢迎页/权限页状态机。

---

## 2. 关键类型

### `BootstrapSnapshot`

文件：

- `Shared/FluentWorkCore/Architecture/AppState.swift`

当前结构：

```swift
public struct BootstrapSnapshot: Equatable, Sendable {
  public var featureFlags: FeatureFlagSnapshot
  public var preferredSurface: WorkspaceSurface
}
```

它承载 bootstrap 成功后要投影进 Store 的启动快照。

### `BootstrapResult`

```swift
public struct BootstrapResult: Equatable, Sendable {
  public var snapshot: BootstrapSnapshot
  public var authInfo: AuthInfo?
}
```

它把启动快照和认证信息打包返回给 middleware。

### `preferredSurfaceProvider`

文件：

- `Shared/FluentWorkCore/Dependencies/AppDependencies.swift`

当前工厂：

```swift
var preferredSurfaceProvider: Factory<@Sendable () -> WorkspaceSurface> {
    self {
        { .speakingRoom }
    }.singleton
}
```

这表示：

1. 生产默认入口是 `.speakingRoom`
2. 但入口策略不是写死在 bootstrap client 里
3. debug / test 可以通过 DI 覆盖

---

## 3. 实际启动链路

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
  -> AppReducer
      -> bootstrapStatus = .ready
      -> workspace.activeSurface = snapshot.preferredSurface
      -> featureFlags / auth / workspace modules 投影
```

对应文件：

- `Shared/FluentWorkCore/Architecture/Middleware/AppBootstrapMiddleware.swift`
- `Shared/FluentWorkCore/Dependencies/AppDependencies.swift`
- `Shared/FluentWorkCore/Architecture/AppReducer.swift`

---

## 4. 生产默认行为

默认情况下，不需要做任何额外配置。

`Container.bootstrapClient` 会使用：

```swift
ResolverBackedBootstrapClient(
    resolver: self.featureFlagResolver(),
    preferredSurfaceProvider: self.preferredSurfaceProvider(),
    sessionAPI: self.sessionAPIClient(),
    tokenStore: self.authTokenStore()
)
```

而 `preferredSurfaceProvider()` 默认返回 `.speakingRoom`。

因此 production 口径是：

1. 启动时拉 feature flags
2. 确保 guest token
3. 默认进入 `speakingRoom`

---

## 5. Debug 下如何覆盖启动入口

文件：

- `Shared/FluentWorkCore/Debug/DebugBootstrapConfiguration.swift`

当前支持三种方式。

### 5.1 直接强制指定 surface

```swift
#if DEBUG
DebugBootstrapConfiguration.forceSurface(.workbench)
#endif
```

适合：

1. 本地手工调试某个入口
2. 快速验证某个 surface 的启动投影

### 5.2 通过 launch arguments

支持：

- `--workbench-first`
- `--review-first`
- `--speaking-room-first`

示例：

```swift
#if DEBUG
DebugBootstrapConfiguration.configureLaunchArgumentOverride()
#endif
```

然后在 Xcode Scheme 中加参数：

```text
--review-first
```

### 5.3 通过 UserDefaults 持久化

```swift
UserDefaults.standard.set("workbench", forKey: "debug.bootstrap.surface")
DebugBootstrapConfiguration.configureFromUserDefaults()
```

适合：

1. 调试菜单
2. 本地多次重启保持同一入口

### 5.4 重置到默认行为

```swift
DebugBootstrapConfiguration.reset()
```

它会：

1. 重置 `preferredSurfaceProvider`
2. 重置 launch argument provider

恢复默认 `.speakingRoom`

---

## 6. 测试里应该怎么用

### 6.1 测试入口策略时，不要依赖真实网络 bootstrap

这类测试目标是验证：

1. provider 默认值
2. override 是否生效
3. debug 配置是否真的改变 bootstrap 结果

因此应该使用假的 bootstrap client，而不是 `ResolverBackedBootstrapClient`。

当前测试文件：

- `Tests/FluentWorkCoreTests/Architecture/BootstrapSurfaceProviderTests.swift`

里面使用了：

```swift
private struct SurfaceOnlyBootstrapClient: BootstrapClientProtocol
```

它只做一件事：

```swift
BootstrapResult(
    snapshot: BootstrapSnapshot(
        featureFlags: .firstWave,
        preferredSurface: preferredSurfaceProvider()
    )
)
```

这样测试只验证 surface 逻辑，不碰网络、鉴权和真实 resolver。

### 6.2 Launch 到导航的 store-level 测试

文件：

- `Tests/FluentWorkCoreTests/Architecture/LaunchToNavigationEndToEndTests.swift`

这里使用 `StaticBootstrapClient`，因为测试重点是：

1. `appLaunched` 后 bootstrap 是否完成
2. `BootstrapSnapshot` 是否正确投影进 Store
3. 导航和 workspace 模块状态是否一致

不是验证真实 backend 是否可连。

---

## 7. 如何在容器里自定义 surface

### 测试容器

```swift
let container = Container()
container.preferredSurfaceProvider.register {
    { .review }
}
container.bootstrapClient.register {
    SurfaceOnlyBootstrapClient(
        preferredSurfaceProvider: container.preferredSurfaceProvider()
    )
}
```

### 共享容器

```swift
Container.shared.preferredSurfaceProvider.register {
    { .workbench }
}
```

注意：

1. `Container.shared` 更适合 debug 配置
2. 并行测试优先使用独立 `Container()`
3. 用完要 reset，避免测试串扰

---

## 8. 新增一个 surface 时怎么做

如果后续需要新增 `WorkspaceSurface`，例如：

```swift
case dailyRead
```

需要同步更新四处：

1. `WorkspaceSurface` 枚举
2. `preferredSurfaceProvider` 的调用方和消费方
3. `DebugBootstrapConfiguration` 的 launch argument / UserDefaults 映射
4. `BootstrapSurfaceProviderTests` 覆盖

如果入口变化还影响导航或模块投影，还要同步补：

5. `LaunchToNavigationEndToEndTests`
6. `AppReducerTests`

---

## 9. 不要再按旧方案扩展

以下口径已经过时，不应继续使用：

1. `BootstrapSurfaceProviderProtocol`
2. `determineBootstrapSurface() async -> BootstrapSurface?`
3. `store.state.bootstrapSurface`
4. `.bootstrap(.completed)` 这类旧 action

如果未来真的要做欢迎页/权限页/引导页多步骤链路，应新建独立的 onboarding / gating 设计，而不是复用当前 `preferredSurface` 方案。

这两者不是一回事：

```text
preferredSurface = 启动后默认落到哪个工作台 surface
onboarding/gating = 是否需要先过一层引导或阻塞流程
```

---

## 10. 当前相关文件

- `Shared/FluentWorkCore/Architecture/AppState.swift`
- `Shared/FluentWorkCore/Architecture/AppReducer.swift`
- `Shared/FluentWorkCore/Architecture/Middleware/AppBootstrapMiddleware.swift`
- `Shared/FluentWorkCore/Dependencies/AppDependencies.swift`
- `Shared/FluentWorkCore/Debug/DebugBootstrapConfiguration.swift`
- `Tests/FluentWorkCoreTests/Architecture/BootstrapSurfaceProviderTests.swift`
- `Tests/FluentWorkCoreTests/Architecture/LaunchToNavigationEndToEndTests.swift`
- `docs/17_Bootstrap设计原理说明.md`

---

## 11. FAQ

### Q1：为什么不直接在 UI 层判断启动进哪个页面？

因为启动入口属于全局状态初始化的一部分，应该通过 bootstrap 收敛，再由 reducer 投影到 Store。这样测试、调试和生产行为才是一致的。

### Q2：为什么不把 `preferredSurface` 写死在 `ResolverBackedBootstrapClient`？

因为 debug / test 需要覆盖，而入口策略不属于网络客户端本身的职责。把它抽成 provider 后，网络逻辑和入口策略就解耦了。

### Q3：为什么测试不用真实 `ResolverBackedBootstrapClient`？

因为那会把测试目标和外部环境绑死。bootstrap provider 测试应该只验证入口策略，不应该因为 backend 不在线而失败。

### Q4：launch arguments 为什么要单独做可测性改造？

因为直接硬读 `CommandLine.arguments` 会让测试只能依赖进程级全局状态。现在通过 `commandLineArgumentsProvider` 间接注入，测试可以稳定验证 `--workbench-first / --review-first / fallback`。
