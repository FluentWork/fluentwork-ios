# FluentWork iOS 技术架构审核与 C0 Gap

**版本**：V1.0  
**日期**：2026-08  
**对应上游**：`32_FluentWork-iOS App端技术设计文档.md` 第 1 / 7 / 8 章

---

## 一、结论

当前 `fluentwork-ios` 仍处于**仓库初始化后、业务骨架未起**的阶段。

现状不是“架构有误”，而是**架构真源已经定了，但仓内还没有把 C0 基座落下来**。因此当前最合理的动作不是先铺页面，而是先完成：

1. 继续以 SPM 作为唯一依赖与模块管理方式
2. 以协议优先的方式冻结系统接缝
3. 把状态、功能控制、网络、插件注册分成独立模块
4. 用 Feature Flag 控制功能开放
5. 用 Moya 作为正式网络实现落点
6. 根 Store / AppState / AppAction
7. C0 级 reducer / middleware / TestStore 基线
8. 说的房间 / 工作台的 `scope` 试点

---

## 二、当前仓现状

截至本次审核并完成本轮 C0 调整后，仓内已有：

1. `Package.swift`
2. `Shared/FluentWorkCore/PackageBaseline.swift`
3. `Tests/FluentWorkCoreTests/PackageBaselineTests.swift`
4. 目录骨架：`App/`、`Modules/`、`Services/`、`Shared/`、`Tests/`
5. CI、OCR、开发入口文档
6. `FluentWorkFeatureFlags` 模块
7. `FluentWorkPluginSupport` 模块
8. `FluentWorkNetworking` 模块

当前仓内仍缺：

1. `AudioEngineProtocol` 正式接口文件
2. `SpeechSession` 正式状态机接口文件
3. 基于 Moya 的真实 API target 定义
4. ~~`SocketTransport` 正式实现~~（I3 已落帧编解码 / 丢帧 / URLSession 传输）
5. 说的房间 UI 与 feature 组装

---

## 三、与技术设计文档的差距

### 1. 已满足的部分

1. iOS 17+ / Swift Package 基线已存在
2. 仓内已有开发入口文档，第一波范围明确
3. 依赖真源仍然在 `meta`，没有复制上游大文档

### 2. 本轮已补齐的 C0 要求

对照技术设计文档第八章 `C0`，本轮已经补齐的关键项有：

1. **TGReduxKit（`from: "5.0.1"`，跟随 5.x 演进）接入**
2. **Factory（exact 3.3.2）接入**
3. **Moya（exact 15.0.3）网络实现落点**
4. **Feature Flag 独立模块**
5. **插件注册独立模块**
6. **根 Store / AppState**
7. **Middleware mock 注入能力**
8. **TestStore 测试矩阵起点**
9. **说的房间 / 工作台 `scope` 试点**
10. **全工程零 Combine 的显式基线**

### 3. 当前仍未进入的部分

本轮完成后，仍然刻意留空、等待后续阶段进入的部分有：

1. `AudioEngine` 正式实现
2. `SpeechSession` 正式状态机实现
3. 基于后端冻结契约的 API target 细化
4. `SocketTransport` 正式实现
5. 说的房间 UI 壳与页面装配

---

## 四、当前阶段的真实阻塞

### 阻塞 1：人写接口尚未正式进仓

技术文档要求：

1. `AudioEngine` 由负责人手写
2. `SpeechSession` 状态机由负责人手写
3. Agent 代码只能依赖其接口，不依赖实现细节

当前这两组接口尚未以正式源码形式进仓，因此本次 C0 只能先做：

1. 根状态树
2. 中间件与依赖注入基座
3. 预留对 `AudioEngineProtocol` / `SpeechSessionClientProtocol` 的接缝

### 阻塞 2：后端契约尚未全部进入 iOS 实现层

`SocketTransport` 与 `APIClient` 的正式实现依赖：

1. WSS schema
2. `POST /sessions`
3. `GET /sessions/:id/review`
4. `POST /account/merge`
5. `POST /sessions/:id/messages`

因此本次 C0 先不进入 C1 / C2 的正式实现，只做依赖注册位与 middleware 骨架。

---

## 五、本次 C0 落地范围

本次只落下面这些内容：

1. Package 依赖升级到 TGReduxKit + Factory + Moya
2. `Feature Flag` 模块
3. `Plugin Registry` 模块
4. `NetworkClientProtocol + MoyaNetworkClient`
5. `AppState`
6. `AppAction`
7. `Auth / SpeakingRoom / Workspace` 三个最小 feature state 与 reducer
8. 根 reducer + cross-cutting reducer
9. `Container` 依赖注册
10. `bootstrap` middleware
11. `AppStoreFactory`
12. TestStore 测试基线

本次**不进入**：

1. 真正的 `AudioEngine` 实现
2. 真正的 `SpeechSession` 状态机实现
3. `SocketTransport` 正式实现
4. `APIClient` 正式实现
5. 说的房间 UI

---

## 六、C0 文件落点

本次建议的仓内结构：

```text
Shared/FluentWorkCore/
  Architecture/
    AppState.swift
    AppReducer.swift
    AppStore.swift
    Features/
      AuthFeature.swift
      SpeakingRoomFeature.swift
      WorkspaceFeature.swift
    Middleware/
      AppBootstrapMiddleware.swift
  Dependencies/
    AppDependencies.swift
Shared/FluentWorkFeatureFlags/
  FeatureFlags.swift
Shared/FluentWorkPluginSupport/
  FeaturePluginRegistry.swift
Shared/FluentWorkNetworking/
  NetworkClient.swift
```

测试基线：

```text
Tests/FluentWorkCoreTests/Architecture/
  AppReducerTests.swift
  AppBootstrapMiddlewareTests.swift
```

---

## 七、这次落地后的判断

如果本次 C0 顺利编过并测试通过，说明：

1. iOS 仓已经从“纯初始化仓”进入“可持续开发仓”
2. 后续 C1 / C2 / C3 可以在已有状态树、Feature Flag、DI、Moya 接缝下推进
3. 人写模块进仓后，只需要替换接缝实现，不需要再重搭全局架构

---

## 八、下一步顺序

本次 C0 后，推荐顺序保持为：

1. 冻结 `AudioEngineProtocol`
2. 冻结 `SpeechSession` 状态机接口
3. 进入 `C1`：`SocketTransport`
4. 进入 `C2`：基于 `Moya` 的 `APIClient`
5. 通过 Feature Flag 控制 `speakingRoom / review` 暴露
6. 再进入 `C3`：说的房间 UI 壳

一句话口径：

> **先把 C0 立起来，再把人写模块接口接进来，而不是先写页面。**
