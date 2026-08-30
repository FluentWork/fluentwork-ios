# FluentWork iOS 第一波 iPhone 17 Pro 模拟器 Smoke Runbook

**版本**：V1.0  
**日期**：2026-08  
**定位**：固定第一波 iOS 活体验证入口，证明 Host 能在指定模拟器启动，且启动 → bootstrap → 说的房间 / 回顾导航最小链路可重复验证  
**对应门禁**：`W1-IOS-3` / `W1-START-1`（见 `fluentwork-meta` 51/52 号文档）

---

## 一、这条 runbook 证明什么

1. 本机存在并可启动 `iPhone 17 Pro` 模拟器
2. `FluentWorkHost` 能在该模拟器上 build / install / launch
3. 第一波启动路径具备可重复测试证据：
   - bootstrap ready
   - 可进入说的房间路由
   - 回顾路由与独立导航栈可用

说明：当前第一波 Host 仍是骨架 UI；本 runbook 的“活体”证据是模拟器启动 + Store 级 launch/navigation 测试，不是完整 XCUITest 点击流。后续可升为 workflow。

---

## 二、前置条件

1. macOS + Xcode（已验证环境：Xcode 26.x）
2. 本机有 `iPhone 17 Pro` 模拟器
3. 仓库根目录存在 `FluentWorkHost.xcodeproj`（可用 `xcodegen generate` 再生）
4. 能执行 `swift test`

检查模拟器：

```bash
xcrun simctl list devices available | grep "iPhone 17 Pro"
```

---

## 三、一键执行

```bash
./Scripts/smoke-iphone17pro.sh
```

可选环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SIMULATOR_NAME` | `iPhone 17 Pro` | 固定机型 |
| `SKIP_HOST_BUILD` | `0` | 设为 `1` 时只跑 launch 测试，不 build Host |

成功退出码为 `0`，并打印：

1. 模拟器 UDID
2. Host launch 是否成功
3. launch/bootstrap 测试通过
4. 日志目录：`.tmp/smoke-iphone17pro/`

失败时优先看：

1. `.tmp/smoke-iphone17pro/xcodebuild-build.log`
2. `.tmp/smoke-iphone17pro/simctl-launch.log`
3. `.tmp/smoke-iphone17pro/swift-test-launch.log`

---

## 四、手动分步（排障用）

### 1. 启动模拟器

```bash
xcrun simctl boot "iPhone 17 Pro" || true
open -a Simulator
```

### 2. Build Host

```bash
xcodebuild \
  -project FluentWorkHost.xcodeproj \
  -scheme FluentWorkHost \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .derivedData/smoke-iphone17pro \
  build
```

### 3. 安装并启动

```bash
APP=$(find .derivedData/smoke-iphone17pro/Build/Products -type d -name FluentWorkHost.app | head -n 1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.fluentwork.host
```

### 4. 跑第一波 launch 路径测试

```bash
swift test --filter 'launchBootstrapsFlagsThenPresentsSpeakingRoom|launchThenSwitchTabKeepsIndependentStacks|appRouteBridgesPluginEntryRoutes'
```

---

## 五、通过标准

全部满足才算 `W1-IOS-3` / `W1-START-1` 过关：

1. 脚本可重复执行，退出码 `0`
2. 输出中明确出现 `iPhone 17 Pro` 与 Host launch 成功（未设 `SKIP_HOST_BUILD`）
3. launch/bootstrap 相关测试全绿
4. 日志落盘，可供关闭记录引用

---

## 六、非本 runbook 范围

1. 真机 QA
2. 真实语音采集 / WSS 联调
3. 完整回顾页内容消费（第二波 `I7`）
4. CI required check 升级（可在本 runbook 稳定后另开）
