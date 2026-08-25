# FluentWork iOS 架构实现约定

**版本**：V1.0
**日期**：2026-08
**定位**：给 `fluentwork-ios` 的日常开发、评审与后续扩展提供统一实现口径
**上游真源**：原则与范围以上游 `fluentwork-meta` 为准；本文只沉淀本仓实现约定

---

## 一、这份文档解决什么问题

当前仓已经完成 `C0` 骨架，但还缺一份“写代码时怎么落”的实现手册。

本文只回答下面这些问题：

1. app 的薄壳应该是什么，不是什么
2. 模块化、插件化、协议优先分别怎样落地
3. `TGReduxKit`、`Factory`、`Moya` 在本仓分别承担什么角色
4. Feature Flag 如何从配置投影到业务状态
5. 测试应该测哪些层，不测哪些层
6. Swift 6 并发约束下，`TGReduxKit` 5.0 使用纯 `@Sendable` Reducer + Middleware→`Effect`

---

## 二、app 薄壳的定义

### 1. 薄壳不是指 `.xcodeproj` 这个文件本身

薄壳首先是一个**职责定义**，不是文件格式定义。

它指的是一个最小宿主 app，只负责：

1. 创建 `Store`
2. 装配依赖容器
3. 触发 `bootstrap`
4. 根据 `AppState` 挂载最小页面或调试入口

它**不负责**承载业务实现细节，也不应该绕开 `Shared/` 下的架构边界直接写业务逻辑。

### 2. 在当前仓内，薄壳最终通常会落成一个最小 app target

当前仓只有 `Package.swift`，还没有 `.xcodeproj` / `.xcworkspace`，`App/` 目录下也只有占位文件。

因此对 FluentWork 来说，更合适的落地方式是：

1. `Shared/` 下继续用 Swift Package 管理核心模块
2. 另外增加一个最小 iOS app host target 作为运行壳
3. app host 只引用 `FluentWorkCore` 等 package product

一句话：

> **薄壳是“最小宿主 app”，实现时大概率会引入一个最小 `.xcodeproj` 或 workspace，但二者不是同义词。**

### 3. 当前阶段薄壳建议只做这些内容

1. `AppStoreFactory.make()`
2. `Container` 默认注册
3. `store.dispatch(.lifecycle(.appLaunched))`
4. 一个最小 root view，显示：
   - `bootstrapStatus`
   - `activeSurface`
   - `availableModules`
5. 一个开发态切换入口，用于验证 Feature Flag 和插件投影

当前**不建议**在薄壳里提前铺：

1. 说的房间正式 UI
2. review 完整 UI
3. 真实音频链路
4. 与第一波目标无关的视觉精修

---

## 三、模块化约定

### 1. 模块边界以“职责稳定性”划分，不以页面数量划分

当前模块边界应保持为：

1. `FluentWorkCore`：状态树、Reducer、Middleware、依赖协议、Store 装配
2. `FluentWorkFeatureFlags`：功能开关模型与开关状态
3. `FluentWorkPluginSupport`：插件描述与注册表
4. `FluentWorkNetworking`：网络客户端协议与 Moya 落点

后续新增模块时，优先按这些边界扩展，而不是先按页面切一堆 target。

### 2. 什么时候该拆新模块

满足以下至少两条，再考虑拆独立 module：

1. 有明确的独立依赖边界
2. 有清晰的公共接口
3. 可以单测而不需要宿主 app
4. 后续会被多个 feature 复用

### 3. 当前不建议的拆法

1. 为单个页面过早拆 target
2. 把 View、Transport、AudioEngine 混在一个模块
3. 把只会被一个 reducer 私有使用的小类型提升成公共模块

---

## 四、协议优先约定

### 1. 先冻结接缝，再接具体实现

当前已经明确预留的接缝有：

1. `BootstrapClientProtocol`
2. `SocketTransportProtocol`
3. `AudioEngineProtocol`
4. `SpeechSessionClientProtocol`
5. `NetworkPluginFactoryProtocol`

这些协议的意义不是“为了抽象而抽象”，而是为了：

1. 先让状态树和流程跑通
2. 让人写模块后接入时不需要重搭架构
3. 让测试可以替换依赖

### 2. 协议文件的要求

1. 只暴露业务所需最小接口
2. 不把第三方库类型直接泄漏到高层模块
3. 方法命名贴近领域动作，而不是实现细节

例如网络层对上只暴露 `NetworkClientProtocol`，而不让上层直接依赖 `MoyaProvider`。

---

## 五、插件化约定

### 1. 插件化在本仓的含义

当前“插件”不是运行时动态加载 bundle，而是：

1. 用 `FeaturePluginDescriptor` 描述一个能力入口
2. 用 `FeaturePluginRegistryProtocol` 统一注册可暴露模块
3. 按 Feature Flag 决定哪些入口对工作台可见

这是一种**能力注册机制**，不是热插拔框架。

### 2. 插件注册表负责什么

注册表负责：

1. 给出有哪些模块可被宿主感知
2. 根据开关快照过滤可用入口

注册表不负责：

1. 创建页面实例
2. 注入页面依赖
3. 直接改动业务状态

### 3. 插件与 Feature Flag 的关系

插件暴露由 Feature Flag 控制，但不能只停留在列表过滤。

当前代码已经明确要求把开关结果投影回业务状态：

1. `speakingRoom.isBootstrapReady`
2. `workspace.availableModules`

因此约定应统一为：

> **Feature Flag 不只是控制入口显示，还要把需要的开关结果投影到业务状态，避免“入口关了但状态还开着”的不一致。**

---

## 六、Redux 约定

### 1. `TGReduxKit` 在本仓的角色

`TGReduxKit` 负责：

1. `Store`
2. `Reducer`
3. `Middleware`
4. `scope`
5. `TestStore`

### 2. reducer 与 middleware 的职责分工

1. reducer：只做同步状态演进
2. middleware：只做副作用、异步流程和依赖调用
3. cross-cutting reducer：处理跨 feature 的状态投影与全局联动

当前 `appCrossCuttingReducer` 就承担了：

1. `bootstrap` 成功后的全局状态投影
2. Feature Flag 变更后的模块投影
3. `badgeHit` 对工作台的联动写入

### 3. 哪些数据不应该进入全局 Store

当前仍应坚持：

1. 高频音频帧
2. 瞬时波形数据
3. 仅为单个 view 服务、且不需要跨模块共享的临时 UI 状态

这些数据进入全局 Store 会放大刷新成本，也会污染状态真源。

---

## 七、Factory 约定

### 1. `Factory` 负责依赖注册，不负责状态管理

当前 `Container` 用来管理：

1. bootstrap client
2. socket transport
3. network client / network plugin factory
4. audio engine
5. speech session client
6. feature plugin registry

### 2. 注册规则

1. 有明确全局单例语义的，优先 `.singleton`
2. 需要共享但不要求全局唯一的，可用 `.shared`
3. 测试中允许覆盖容器注册，不允许 view 侧自行 new 底层依赖

---

## 八、Moya 约定

### 1. `Moya` 的定位

`Moya` 是正式 HTTP 实现落点，不是上层直接依赖对象。

当前建议保持三层：

1. `FluentWorkTargetType`：接口描述
2. `NetworkClientProtocol`：对上暴露的最小请求能力
3. `MoyaNetworkClient`：具体实现

### 2. 后续扩展规则

1. 每组后端契约先定义 target
2. 业务层只依赖返回的领域模型或 DTO
3. 不在 view 或 reducer 中直接写 `MoyaProvider`

---

## 九、测试约定

### 1. 当前最该优先补的测试

1. reducer 状态演进测试
2. middleware 流程测试
3. Feature Flag 投影测试
4. 游客转注册状态迁移测试
5. 插件启停对工作台模块列表的影响测试

### 2. 当前测试工具口径

1. 用 `TestStore` 测 reducer / middleware
2. 用 stub client 替代真实网络
3. 用 `Factory` 覆盖依赖容器

### 3. 当前不优先的测试

1. 视觉快照测试
2. 与第一波目标无关的 UI 录制测试
3. 直接对第三方库行为做重复性测试

---

## 十、Swift 6 并发与 TGReduxKit

### 1. 库侧契约（5.0.0）

`TGReduxKit` `5.0` 定稿为「纯 Reducer + Middleware→Effect」：

1. `Reducer` 是 `@Sendable (inout State, Action) -> Void`，不返回副作用
2. `Middleware` 返回声明式 `Effect`；由 root `Store` 解释执行与取消
3. 单一 `@MainActor @Observable` `Store`；`ScopedStore` / `StoreType` 仍服务 View 投影
4. `State` / `Action` 需遵循库协议；依赖只在 Middleware 工厂注入（本仓继续用 Factory）
5. `TestStore` 在独立产品 `TGReduxKitTesting` 中，只做纯 reducer 同步断言

### 2. 项目侧约定

1. Feature / root reducer 保持纯函数，不加 `@MainActor`
2. 异步 IO 只通过 Middleware 返回 `Effect.task` / `.debounce` 等
3. Feature View 可读 `Store` 或 `ScopedStore`；任务生命周期留在 root store

### 3. 不建议的方向

1. 在 Reducer 里做网络 / 时间 / UUID
2. 在 Middleware 里直接 `Task {}` 绕过 `Effect`
3. 让 `ScopedStore` 自行管理任务生命周期

---

## 十一、当前统一口径

1. app 薄壳是一个最小宿主 app，不等于 `.xcodeproj` 本身
2. `Shared/` 下的模块继续作为真实业务与架构承载层
3. 插件化在本仓表示“能力注册 + 开关过滤”，不是动态加载
4. Feature Flag 必须同步投影到业务状态
5. reducer 只管同步演进，副作用统一走 middleware → `Effect`
6. Swift 6 并发下，`Store` / Middleware 在 `@MainActor`，`Reducer` 保持 `@Sendable` 纯函数
