# TGReduxKit Swift 6 并发修复建议

**版本**：V1.0
**日期**：2026-08
**定位**：整理 `TGReduxKit` 在 Swift 6 严格并发检查下的现象、最小复现、候选修法与推荐建议，方便直接和库作者沟通

---

## 一、问题摘要

在 Swift 6 严格并发检查下，如果 `Reducer` 仍定义为普通闭包：

```swift
public typealias Reducer<State, Action> = (inout State, Action) -> Void
```

那么当业务侧把 reducer 声明成全局 `let` 常量时，会触发并发安全诊断。

当前 FluentWork iOS 的业务写法正是这一类：

1. reducer 作为模块级全局常量暴露
2. `Store` 是 `@MainActor`
3. `Middleware` 也是 `@MainActor`

所以问题不在业务逻辑本身，而在于：

> **`Store` / `Middleware` 的并发语义已经收口到 MainActor，但 `Reducer` 的公开类型契约仍是非隔离普通闭包。**

---

## 二、最小复现

下面这段代码可以稳定复现问题：

```swift
import Foundation

public typealias Reducer<State, Action> = (inout State, Action) -> Void

public struct AppState: Sendable {
    public init() {}
}

public enum AppAction: Sendable {
    case ping
}

@MainActor
public final class Store<State, Action> {
    private let reducer: Reducer<State, Action>

    public init(reducer: @escaping Reducer<State, Action>) {
        self.reducer = reducer
    }
}

public let appReducer: Reducer<AppState, AppAction> = { state, action in
    switch action {
    case .ping:
        break
    }
}
```

复现命令：

```bash
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -typecheck repro.swift
```

实际编译器报错如下：

```text
error: let 'appReducer' is not concurrency-safe because non-'Sendable' type
'Reducer<AppState, AppAction>' (aka '(inout AppState, AppAction) -> ()')
may have shared mutable state

note: a function type must be marked '@Sendable' to conform to 'Sendable'
note: add '@MainActor' to make let 'appReducer' part of global actor 'MainActor'
```

---

## 三、为什么 FluentWork 会碰到这个问题

FluentWork iOS 当前的使用模式是：

1. reducer 作为模块级常量，例如 `appReducer`
2. `Store` 运行在 `@MainActor`
3. `Middleware` 运行在 `@MainActor`
4. UI app 直接持有 `Store`，状态更新默认发生在主线程

也就是说，这个库在真实使用上已经是一个**主线程驱动的 UI 状态管理库**。

在这种前提下，如果 `Reducer` 类型仍然保持为普通闭包，Swift 6 会认为：

1. 全局 `let reducer` 可能被跨并发域共享
2. 该闭包类型本身不是 `Sendable`
3. 因而这份全局常量不具备并发安全保证

---

## 四、候选修法

### 方案 A：把 `Reducer` 改成 `@Sendable`

```swift
public typealias Reducer<State, Action> = @Sendable (inout State, Action) -> Void
```

优点：

1. 直接满足编译器对函数类型 `Sendable` 的要求
2. 是最小的并发语义补充

缺点：

1. 只能说明这个闭包可跨并发域传递
2. 不能表达 `TGReduxKit` 当前真实使用模型已经主要收口在 MainActor

### 方案 B：把 `Reducer` 改成 `@MainActor`

```swift
public typealias Reducer<State, Action> = @MainActor (inout State, Action) -> Void
```

优点：

1. 与当前 `Store` / `Middleware` 语义一致
2. 明确告诉业务方：reducer 默认就在主 actor 上运行
3. 业务侧不需要再为每个全局 reducer 单独补 `@MainActor`

缺点：

1. 这是比 `@Sendable` 更强的语义收口
2. 等于正式承认 `TGReduxKit` 是主线程驱动的 app/store 模型

### 方案 C：把 `Reducer` 改成 `@MainActor @Sendable`

```swift
public typealias Reducer<State, Action> = @MainActor @Sendable (inout State, Action) -> Void
```

优点：

1. 同时表达 actor 隔离和可安全传递
2. 语义最完整

缺点：

1. 对外契约变化最强
2. 对维护者来说需要更明确地承诺这个类型的定位

---

## 五、推荐建议

### 推荐主建议

优先建议作者采用 **方案 B：`@MainActor`**：

```swift
public typealias Reducer<State, Action> = @MainActor (inout State, Action) -> Void
```

原因很简单：

1. `Store` 已经是 `@MainActor`
2. `Middleware` 已经是 `@MainActor`
3. app 侧的状态演进本来就围绕 UI 主线程展开

所以把 `Reducer` 对齐到 `@MainActor`，是最符合现有库模型的修法。

### 可选增强建议

如果作者希望把并发契约表达得更完整，可以评估：

```swift
public typealias Reducer<State, Action> = @MainActor @Sendable (inout State, Action) -> Void
```

这个版本更“显式”，但也更强，因此更适合作为维护者明确接受后的升级方向。

---

## 六、不推荐的处理方式

不建议把问题留给业务项目各自解决，例如：

1. 每个业务 reducer 都手动写 `@MainActor`
2. 用 `@unchecked Sendable` 压制问题
3. 用 `nonisolated(unsafe)` 或其他方式跳过检查

这些方式虽然短期能过编译，但会把库层契约不一致的问题外溢到所有接入方。

---

## 七、建议和作者沟通时的表述

下面这段话可以直接发给作者：

```text
我在 Swift 6 严格并发检查下接入 TGReduxKit 时，遇到一个和 Reducer 类型契约有关的问题。

当前 TGReduxKit 的 Store 是 @MainActor，Middleware 也是 @MainActor，但 Reducer 还是普通闭包：

public typealias Reducer<State, Action> = (inout State, Action) -> Void

在这种定义下，如果业务侧把 reducer 写成模块级全局 let：

public let appReducer: Reducer<AppState, AppAction> = { ... }

Swift 6 会报：

let 'appReducer' is not concurrency-safe because non-'Sendable' type
'Reducer<AppState, AppAction>' may have shared mutable state

我做了一个最小复现，确认把 Reducer 改成下面任一形式都可以消除报错：

1. @Sendable (inout State, Action) -> Void
2. @MainActor (inout State, Action) -> Void
3. @MainActor @Sendable (inout State, Action) -> Void

结合 TGReduxKit 现在 Store / Middleware 已经是 MainActor 语义，我更倾向于建议把 Reducer 也收口到 @MainActor。这样业务侧不需要为每个全局 reducer 单独补 @MainActor，库的公开并发契约也会更一致。
```

---

## 八、结论

这不是 FluentWork 单独的业务问题，而是 `TGReduxKit` 在 Swift 6 下一个公开契约尚未完全收口的问题。

一句话总结：

> **如果 `TGReduxKit` 的 Store 模型默认就是 UI 主线程驱动，那么 `Reducer` 的类型契约最好也同步对齐到 MainActor。**
