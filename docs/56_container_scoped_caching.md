# `.singleton` 缓存的是**进程**，不是容器

**日期**：2026-09-11
**状态**：实现与测试已齐。
**对应**：meta `77_` **P1-9** · 症状最早见 ios `docs/48`（`processingTimeouts` 那次）

## 1. 为什么

`77_` P1-9 记的是四个工厂：`corpusCacheStore` / `corpusOutboxStore` / `corpusSyncMetadataStore` / `networkMonitor` 都被测试 `register` 过，而它们都是 `.singleton`。

症状是**"别的测试拿到你这个假 cache"** —— 一个测试注册的替身，会出现在另一个**并发**运行的测试里。`defer` 还原救不了，因为它只在测试结束后生效，而那些测试**同时在跑**。

## 2. 根因：FactoryKit 的 Singleton 作用域**绕开容器缓存**

`FactoryKit` 的 `Scope.Singleton` 自己写着这件事：

```swift
internal override func resolve<T>(using cache: Cache, key: FactoryKey, ttl: TimeInterval?, factory: () -> T) -> (T, Bool) {
    // ignore container's cache in favor of our own
    return super.resolve(using: self.cache, key: key, ttl: ttl, factory: factory)
}
```

**注释是字面的**：它忽略传进来的容器缓存，改用 `self.cache`。而 `self` 是 `Scope.singleton` —— 一个**共享实例**。

所以：

- **`Container()` 是不是新的，无关紧要。** 值缓存在容器之外。
- **`container.reset()` 清不掉它。** `reset(.all)` 清的是 `self.cache`（容器自己的）。
- **`defer` 还原也没用。** 泄漏发生在注册的那一刻，落点是一个所有容器共享的缓存。

这解释了一个此前只能靠症状描述的现象：为什么**换了 `Container()` 实例仍然串味**。

### 顺带纠正一处措辞

`77_` 猜的修法方向是"值类型去掉 `.singleton`；有状态替身需要 per-test 隔离，而 FactoryKit 的单例缓存正好破坏这一点 —— **需先确认其缓存作用域语义**"。

**确认完了**：不是"单例缓存破坏隔离"，是**单例作用域根本不在容器里**。所以有状态替身不需要额外的隔离机制 —— 它需要的是**换一个作用域**。

## 3. 修法：`.singleton` → `.cached`

`Scope.Cached` **不覆写 `resolve`**，所以它用的是**传进来的那个缓存** —— 也就是容器的缓存：

```swift
public final class Cached: Scope, @unchecked Sendable {
    public override init() { super.init() }
}   // 无自有 cache、无 resolve 覆写
```

于是：

| | `.singleton` | `.cached` |
|---|---|---|
| 缓存在哪 | `Scope.singleton`（进程共享） | 容器自己的 cache |
| 新建容器 | **仍拿到同一个值** | 各自一份 |
| `container.reset()` | 清不掉 | 清得掉 |

## 4. 范围：改的是**全部** 25 处，不只是台账那四个

台账点名的四个是**被证明会漏的**。但那 25 处**每一处都是同一个隐患**，而且有一件更基本的事支持全改：

> **生产代码永远走 `Container.shared`。**

`AppStore`、四个 `*Middleware` 工厂、`AppBootstrapMiddleware` 的签名都是
`container: Container? = nil` → `container ?? Container.shared`，而**生产调用点一个 `container:` 都没传**。
那个参数存在的唯一目的，就是**让测试能注入一个新的容器**。

而 `.singleton` **恰好废掉了这个注入** —— 它让"注入一个干净容器"这件事在缓存层面不成立。

所以在生产里 `.cached` 与 `.singleton` **行为完全一致**（一个容器、从不 reset）；在测试里前者才实现了后者承诺的隔离。
**这不是"宽改动"，是让 DI 的设计意图成立。**

> 一处不动：`processingTimeouts`。它**故意没有** `.singleton`（无状态值类型，缓存本就没有意义），
> 已经由 `docs/48` 修过，注释就写在声明上方。

## 5. 门禁与红验证

```bash
swift test          # 458 tests passed  (456 + 2 新增)
xcodebuild ... -scheme FluentWorkHost -configuration Debug build   # BUILD SUCCEEDED
```

### 修复前的实际失败输出（不是转述）

```
✘ Test freshContainersDoNotShareCachedState() recorded an issue at ContainerIsolationTests.swift:47:5:
  Expectation failed: ((first.corpusCacheStore() as? JSONCorpusCacheStore) → JSONCorpusCacheStore)
  !== ((second.corpusCacheStore() as? JSONCorpusCacheStore) → JSONCorpusCacheStore)
↳ corpusCacheStore is shared across containers
   …同样四条：corpusOutboxStore / corpusSyncMetadataStore / networkMonitor

✘ Test aRegisteredFakeDoesNotReachAnotherContainer() recorded an issue at ContainerIsolationTests.swift:86:5:
  Expectation failed: (other.corpusCacheStore() as? MarkerCacheStore) !== (fake → MarkerCacheStore)
↳ a fake registered in one container leaked into another
```

**四个工厂全部泄漏，注册的替身也泄漏** —— 与台账描述的症状逐字对上。

### 红验证

把一个工厂改回 `.singleton`（`corpusCacheStore`）：

```
✘ Test freshContainersDoNotShareCachedState() … ↳ corpusCacheStore is shared across containers
```

红的正是预料的那条。改回即绿。

### 守卫为什么写成"性质"而不是"点名"

`freshContainersDoNotShareCachedState` 断言的是**两个独立容器不共享同一个实例**，
而不是"某个工厂的 scope 是 `.cached`"。这样将来**新加**的工厂若也用了 `.singleton`，
守卫照样抓得住 —— 点名的写法只能守住今天已知的四个。

## 6. 顺带撞出一个编译器 bug

身份比较最初写成：

```swift
(first.corpusCacheStore() as AnyObject) !== (second.corpusCacheStore() as AnyObject)
```

**Swift 6.3.3 编译器直接崩掉**（`compile command failed due to signal 6` / `fatal error encountered during compilation`），
不是报类型错误。换成先转型到具体类型再比较即可：

```swift
(first.corpusCacheStore() as? JSONCorpusCacheStore) !== (second.corpusCacheStore() as? JSONCorpusCacheStore)
```

记在这里是因为它**看起来像自己的代码写错了**，而实际是工具链的问题 —— 下一次遇到同样的崩溃可以直接跳过这段排查。

## 7. 影响面

| 维度 | 影响 |
|---|---|
| **生产行为** | **无改动**。单一 `Container.shared`、从不 `reset()` ⇒ `.cached` 与 `.singleton` 同义 |
| **测试** | 新建容器**真正**是干净的了；"注册替身→并发跑另一个测试"这类串味不再可能 |
| **DI 接线** | 25 处作用域修饰符；**无调用点改动** |
| **风险面** | `AppDependencies.swift` 是 `docs/48` 与 `74_` 都点过的高风险区（根 store / 依赖注入），所以本票**只改作用域、不改任何构造闭包**，且以全量 `swift test` + Debug build 为界 |

## 8. 未做

- **`InMemorySocketTransport` 那类替身的注入路径**没有单独审 —— 本票修的是作用域，注入方式未动。
- **没有给 25 处逐一加守卫**。守卫断言的是性质（两个容器不共享），覆盖面是"任何被一个容器缓存的东西"，
  不需要逐一枚举。
