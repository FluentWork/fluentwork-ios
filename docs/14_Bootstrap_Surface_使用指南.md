# Bootstrap Surface 使用指南

## 概述

Bootstrap Surface 是 FluentWork iOS 应用启动流程的抽象层，用于在启动时显示不同的 UI 界面（欢迎屏、权限请求、功能介绍等）。它解决了以下问题：

1. **启动流程的灵活性**：可以根据用户状态（首次安装、版本升级、权限缺失）显示不同的界面
2. **解耦启动 UI 和业务逻辑**：启动流程和主应用逻辑分离
3. **测试友好**：通过 Provider 模式可以轻松 mock 不同的启动场景

## 架构设计

### 核心组件

```
BootstrapSurfaceProvider
    ├── determineBootstrapSurface() → BootstrapSurface?
    └── 返回 nil 表示直接进入主应用
    
BootstrapSurface (enum)
    ├── welcome           // 欢迎屏
    ├── permissions       // 权限请求
    ├── featureIntro      // 功能介绍
    └── ... (可扩展)
```

### 启动流程

```
App 启动
    ↓
RootReducer 处理 .appLaunched
    ↓
BootstrapSurfaceProvider.determineBootstrapSurface()
    ↓
    ├─ 返回 surface → 显示 Bootstrap UI
    │       ↓
    │   用户完成操作 → dispatch(.bootstrap(.completed))
    │       ↓
    └─ 返回 nil → 直接进入主应用
```

## 使用方法

### 1. 实现自定义 Provider

创建一个类实现 `BootstrapSurfaceProviderProtocol`：

```swift
import FluentWorkCore

final class MyBootstrapProvider: BootstrapSurfaceProviderProtocol {
    func determineBootstrapSurface() async -> BootstrapSurface? {
        // 检查是否需要显示欢迎屏
        if isFirstLaunch() {
            return .welcome
        }
        
        // 检查麦克风权限
        if !hasMicrophonePermission() {
            return .permissions
        }
        
        // 不需要 Bootstrap，直接进入主应用
        return nil
    }
    
    private func isFirstLaunch() -> Bool {
        // 实现逻辑
    }
    
    private func hasMicrophonePermission() -> Bool {
        // 实现逻辑
    }
}
```

### 2. 注册到 DI 容器

在 `AppDependencies.swift` 中注册：

```swift
extension Container {
    var bootstrapSurfaceProvider: Factory<BootstrapSurfaceProviderProtocol> {
        self { MyBootstrapProvider() }.singleton
    }
}
```

### 3. 创建 Bootstrap UI

根据 `BootstrapSurface` 类型创建对应的 SwiftUI View：

```swift
import SwiftUI
import FluentWorkCore

struct BootstrapView: View {
    let surface: BootstrapSurface
    let onComplete: () -> Void
    
    var body: some View {
        switch surface {
        case .welcome:
            WelcomeView(onComplete: onComplete)
        case .permissions:
            PermissionsView(onComplete: onComplete)
        case .featureIntro:
            FeatureIntroView(onComplete: onComplete)
        }
    }
}

struct WelcomeView: View {
    let onComplete: () -> Void
    
    var body: some View {
        VStack {
            Text("欢迎使用 FluentWork")
            Button("开始使用", action: onComplete)
        }
    }
}
```

### 4. 在根视图中使用

```swift
import SwiftUI
import FluentWorkCore

struct RootView: View {
    @EnvironmentObject var store: Store<AppState, AppAction>
    
    var body: some View {
        Group {
            if let surface = store.state.bootstrapSurface {
                BootstrapView(surface: surface) {
                    store.send(.bootstrap(.completed))
                }
            } else {
                MainAppView()
            }
        }
    }
}
```

## 内置示例

项目提供了两个内置示例（仅在 DEBUG 模式可用）：

### 1. AlwaysWelcomeBootstrapProvider

每次启动都显示欢迎屏：

```swift
#if DEBUG
container.bootstrapSurfaceProvider.register {
    AlwaysWelcomeBootstrapProvider()
}
#endif
```

### 2. NoBootstrapProvider

跳过 Bootstrap，直接进入主应用：

```swift
#if DEBUG
container.bootstrapSurfaceProvider.register {
    NoBootstrapProvider()
}
#endif
```

## Debug 配置

在 `DebugBootstrapConfiguration.swift` 中可以切换不同的 Provider：

```swift
#if DEBUG
import Foundation

public enum DebugBootstrapConfiguration {
    public static let useAlwaysWelcome = false // 改为 true 启用
}
#endif
```

## 测试

### 单元测试

```swift
import Testing
@testable import FluentWorkCore

@Test func bootstrapProviderReturnsWelcomeOnFirstLaunch() async {
    // Given
    let provider = MyBootstrapProvider()
    // 模拟首次启动
    
    // When
    let surface = await provider.determineBootstrapSurface()
    
    // Then
    #expect(surface == .welcome)
}

@Test func bootstrapProviderReturnsNilWhenSetupComplete() async {
    // Given
    let provider = MyBootstrapProvider()
    // 模拟已完成设置
    
    // When
    let surface = await provider.determineBootstrapSurface()
    
    // Then
    #expect(surface == nil)
}
```

### 端到端测试

参考 `LaunchToNavigationEndToEndTests.swift`：

```swift
@Test func appLaunchWithBootstrapShowsWelcome() async throws {
    let container = Container()
    container.bootstrapSurfaceProvider.register {
        AlwaysWelcomeBootstrapProvider()
    }
    
    let store = Store(
        initialState: AppState(),
        reducer: rootReducer,
        environment: container
    )
    
    await store.send(.appLaunched)
    
    #expect(store.state.bootstrapSurface == .welcome)
}
```

## 常见场景

### 场景 1：首次安装引导

```swift
func determineBootstrapSurface() async -> BootstrapSurface? {
    let isFirstLaunch = UserDefaults.standard.bool(forKey: "has_launched") == false
    
    if isFirstLaunch {
        UserDefaults.standard.set(true, forKey: "has_launched")
        return .welcome
    }
    
    return nil
}
```

### 场景 2：权限检查

```swift
import AVFoundation

func determineBootstrapSurface() async -> BootstrapSurface? {
    let status = AVAudioSession.sharedInstance().recordPermission
    
    if status == .undetermined || status == .denied {
        return .permissions
    }
    
    return nil
}
```

### 场景 3：版本升级引导

```swift
func determineBootstrapSurface() async -> BootstrapSurface? {
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let lastVersion = UserDefaults.standard.string(forKey: "last_version")
    
    if currentVersion != lastVersion {
        UserDefaults.standard.set(currentVersion, forKey: "last_version")
        return .featureIntro // 显示新功能介绍
    }
    
    return nil
}
```

### 场景 4：多步骤引导

```swift
enum OnboardingStep: String {
    case welcome
    case permissions
    case tutorial
}

func determineBootstrapSurface() async -> BootstrapSurface? {
    let completedSteps = UserDefaults.standard.stringArray(forKey: "completed_steps") ?? []
    
    if !completedSteps.contains(OnboardingStep.welcome.rawValue) {
        return .welcome
    }
    
    if !completedSteps.contains(OnboardingStep.permissions.rawValue) {
        return .permissions
    }
    
    if !completedSteps.contains(OnboardingStep.tutorial.rawValue) {
        return .featureIntro
    }
    
    return nil
}

// 完成某步骤时调用
func completeStep(_ step: OnboardingStep) {
    var completed = UserDefaults.standard.stringArray(forKey: "completed_steps") ?? []
    completed.append(step.rawValue)
    UserDefaults.standard.set(completed, forKey: "completed_steps")
}
```

## 扩展 BootstrapSurface

如果需要新的 Bootstrap 类型：

1. 在 `BootstrapSurface` 枚举中添加新 case：

```swift
public enum BootstrapSurface: Equatable, Sendable {
    case welcome
    case permissions
    case featureIntro
    case accountSetup // 新增
}
```

2. 创建对应的 UI View

3. 在 Provider 中返回新的 surface

## 注意事项

1. **Provider 应该是无状态的**：不要在 Provider 中保存状态，所有状态应该存储在持久化层（UserDefaults、Keychain 等）

2. **异步操作**：`determineBootstrapSurface()` 是 async 方法，可以执行网络请求或其他异步操作

3. **线程安全**：Provider 会在后台线程调用，确保实现是线程安全的

4. **性能考虑**：Provider 在每次启动时调用，避免执行耗时操作

5. **测试覆盖**：为 Provider 编写单元测试，覆盖所有可能的启动路径

## 相关文件

- `Shared/FluentWorkCore/Architecture/BootstrapSurfaceProvider.swift` - 协议定义
- `Shared/FluentWorkCore/Debug/BootstrapSurfaceExamples.swift` - 示例实现
- `Shared/FluentWorkCore/Debug/DebugBootstrapConfiguration.swift` - Debug 配置
- `Tests/FluentWorkCoreTests/Architecture/BootstrapSurfaceProviderTests.swift` - 单元测试
- `Tests/FluentWorkCoreTests/Architecture/LaunchToNavigationEndToEndTests.swift` - 端到端测试

## FAQ

### Q: 如何跳过 Bootstrap 直接进入主应用？

A: Provider 返回 `nil` 即可：

```swift
func determineBootstrapSurface() async -> BootstrapSurface? {
    return nil
}
```

### Q: 如何在 Debug 模式快速测试不同的 Bootstrap？

A: 使用 `DebugBootstrapConfiguration` 或直接在 DI 容器中注册示例 Provider。

### Q: Bootstrap 完成后如何清理状态？

A: 发送 `.bootstrap(.completed)` 后，RootReducer 会自动将 `bootstrapSurface` 设置为 `nil`，状态由 Provider 管理（如 UserDefaults）。

### Q: 可以有多个连续的 Bootstrap 吗？

A: 可以。每次完成一个步骤后，重新调用 Provider，它会返回下一个需要显示的 surface，直到返回 `nil`。

### Q: 如何处理用户跳过 Bootstrap？

A: 在 UI 层提供"跳过"按钮，点击时同样调用 `store.send(.bootstrap(.completed))`，但在 Provider 逻辑中记录用户跳过了哪些步骤。
