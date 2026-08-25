# FluentWork iOS 基础组件分析与引入清单

**版本**：V1.1
**日期**：2026-08
**定位**：盘点骨架缺口，给出自建 / 开源结论、Shared 落点，以及日后外迁到 FluentWork 同组织仓库的路径
**上游真源**：`fluentwork-meta`（`32_FluentWork-iOS App端技术设计文档` 第 1/4/6 章、`30_技术方案` 6.2/6.3、`21_界面设计文档` 第三章）

---

## 一、这份文档解决什么问题

C0 基座（根 Store / DI / Feature Flag / 插件注册 / Moya 接缝）已经落仓，但从「可持续开发」到「能承接 I1-I6」之间还缺一批**横切基础组件**。本文给出缺口依据、落点与引入顺序。

> **执行口径**：在 `Shared/` 落地可拆模块；公开 API 保持无业务页污染。稳定后外迁到与 `fluentwork-meta` / `fluentwork-infra` **同组织**的仓库；单仓多 package vs 多仓形态外迁前再定。

---

## 二、仓内现状盘点

### 已有

1. `Package.swift`：TGReduxKit（from 5.0.1）+ Factory（exact 3.3.2）+ Moya（branch master）+ TGNavigationStack（from 1.1.0）+ TGFeatureFlag（from 0.5.0，Resolver→Redux）
2. 模块：`FluentWorkCore` / `FluentWorkFeatureFlags` / `FluentWorkPluginSupport` / `FluentWorkNetworking` / `FluentWorkDiagnostics` / `FluentWorkUI`
3. 根 Store / AppState / AppReducer / bootstrap middleware / TestStore 基线
4. 宿主壳：`FluentWorkHost.xcodeproj` + `HostRootView`
5. 协议接缝：`BootstrapClient` / `SocketTransport` / `AudioEngine` / `SpeechSessionClient` / `NetworkPluginFactory`（多为 Placeholder）
6. 插件化：`FluentWorkPluginSupport` 为**能力注册 + Flag 过滤**（非动态加载）；无需另引开源插件框架

### 本批补齐范围

1. 统一日志（Logger）
2. 导航基座（Tab + TGNavigationStack）
3. Design Tokens
4. 安全存储（Keychain 接缝）
5. 网络状态监测
6. API 错误归一化
7. 埋点接缝（TrackerClient）
8. 可注入时间 / UUID
9. 环境配置

---

## 三、逐项结论与落点

| 组件 | 结论 | Shared 落点 | 同组织外迁候选 |
|---|---|---|---|
| A. Logger | 自建 OSLog 薄封装 | `FluentWorkDiagnostics` | foundation / diagnostics 包 |
| B. 导航 | **TGNavigationStack** ≥1.1.0 + App 侧 Tab/`Codable` Route | `FluentWorkCore/Navigation/` + Host | Navigation 已独立；Tab 编排可留 Core |
| Feature Flag 解析 | **TGFeatureFlag** ≥0.5.0 Resolver；**Store 仍为 SoT** | `FluentWorkFeatureFlags` + Core bootstrap | TGFeatureFlag 已独立 |
| C. Design Tokens | 自建常量 | `FluentWorkUI/DesignTokens/` | UI kit / tokens 包 |
| D. 安全存储 | 自建 Security 薄封装 | `FluentWorkCore/Storage/` | foundation |
| E. 网络监测 | 自建 NWPathMonitor | `FluentWorkNetworking` + `AppState.network` | networking |
| F. API 错误归一化 | 自建 `APIError` | `FluentWorkNetworking` | networking |
| G. 埋点接缝 | 协议先行 | `FluentWorkDiagnostics` | foundation |
| H. 时间 / UUID | 自建可注入协议 | `FluentWorkCore/Dependencies/` | foundation |
| I. 环境配置 | 自建 | `FluentWorkCore` | 可随 Core 或 foundation |

**白名单**：技术方案 6.3（meta V3.4）已含 TGReduxKit / Factory / TGNavigationStack / TGFeatureFlag / Moya / SwiftLint / Pulse。Pulse / SwiftLint 口径不变；Pulse 仍暂缓。

### 外迁三阶段

1. **In-tree**：`Shared/<Module>` + Package product  
2. **接口冻结**：无产品页 / 无音频实现泄漏  
3. **同组织仓库**：打 semver；本仓改为 git 依赖。仓形（单仓多 package vs 多仓）外迁前拍板。

---

## 四、引入顺序与验收

### 第一批（I3/I4 前置）

Logger → API 错误归一化 → 网络监测 → 安全存储 → 时间/UUID → 环境配置

### 第二批（I5 前置）

导航基座（TGNavigationStack + 3 Tab）→ Design Tokens

### 第三批

埋点接缝（不上报通道）

### 验收

1. 协议 + 可替换实现 + 单测  
2. `swift test` 全绿  
3. 不提前铺说的房间正式 UI / 真实音频链路  

---

## 五、本批明确不做

1. 说的房间 / 回顾页正式 UI（I5 / I6）  
2. `APIClient` 正式实现（I4）；`SocketTransport` 已在 I3 落地  
3. 真实埋点上报、Pulse、SwiftData、快照测试基建  
4. 把 `@Observable FeatureFlagService` 当业务真源（本仓只用 Resolver → `applyRemoteSnapshot`）  

---

## 六、一句话口径

> **横切组件先落 Shared 可拆模块；导航用 TGNavigationStack；稳定后外迁 FluentWork 同组织仓库；每批以现有测试矩阵全绿为闸。**
