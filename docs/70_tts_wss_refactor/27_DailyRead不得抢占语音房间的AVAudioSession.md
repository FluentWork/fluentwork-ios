# 27 — 实现说明：Daily Read 不得抢占语音房间的 `AVAudioSession`

> 对应条目：`80_架构分析/05_问题清单与建议.md` **S1-10**（本轮立）。
> 事故：**2026-09-24 真机** —— 练习会话卡在 `.connecting`，直到 10s 看门狗把它判失败。
> 改动：`DailyReadAudioPlayer.swift`（新增 `configurePlaybackCategoryIfUncontested`，两处调用点改走它）、
> `LiveAudioEngine.swift`（新增 `describeSession()`，两处诊断点带上它）、
> `AppDependencies.swift`（`captureArmed` 加第 5 个关联值 `session`）、
> `SpeechSessionMiddleware.swift`（`captureArmed` 多报一个键；新增 `session_interrupted_by_system` 埋点）、
> `SpeakingRoomSessionWiringTests.swift`（键表补 `session`；新增 1 条独立测试）。
> 测试数：`590 → 591`。
> **可观测那一半有「先红」**（两次变异验证，逐字输出见 §5）；**音频那一半没有**，理由见 §6 —— 它落在本仓测试层级之外，这是 `80_/03_` §4.5 早已记录的事实，不是本条的遗漏。

## 1. 这条改动守的是什么契约

**同一个进程里只有一条音频输入通道，而它属于语音房间。别的组件可以共用这条 `AVAudioSession`，但不能把它的 category 从 `.playAndRecord` 改走。**

理由不是「谁更重要」，而是一个**非对称的后果**：把 category 从 `.playAndRecord` 改走会拆掉 input route，而 `AVAudioEngine` 会**在一行我们的代码都不执行的情况下自己停下来**。反过来不成立 —— `AVPlayer` 在 `.playAndRecord` 下照样能放。

所以这条契约不是「谁赢」，而是 **「谁可以不赢」**：Daily Read **不需要赢这场争夺，只需要不替对方输掉**。

## 2. 为什么这是缺陷

### 2.1 事故链（真机 2026-09-24）

1. 练习会话正常起来，`LiveAudioEngine` 通过 `sessionManager.configure(for: .fullDuplex)` 把 session 设成 `.playAndRecord` + `.voiceChat`（`LiveAudioEngine.swift:459`）。
2. Daily Read 同时要放音频，并且要能在锁屏下继续放，于是它调用 `AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])`。
3. **改 category 拆掉了 input route。** `AVAudioEngine` 因此在**没有任何我们的代码执行**的情况下停了 —— 没有抛错、没有回调、没有栈。
4. 会话卡在 `.connecting`，10s 后看门狗把它判为失败。

### 2.2 为什么它在日志里不可归因

这是本条真正的痛点，也是 §4 存在的理由。

失败发生时，`LiveAudioEngine` 只报得出「`engine.isRunning == false`」。而**让引擎停下来的两条路都留下同样的痕迹**：

| 成因 | 谁停的 | 日志里看得见吗 |
|---|---|---|
| 系统中断（来电、别的 app 抢） | 系统 | `.interruptedBySystem` **当时只派发、不埋点** —— 有没有它，日志长得一模一样 |
| 本 app 内另一个组件改了 session | `DailyReadAudioPlayer` | 完全没有痕迹 —— 它不经过任何共享的归属点 |

`captureKick` 当时报的是 `playing`（即 `startKeepAlive` 刚确认过引擎在跑），而紧接着的 `captureArmed` 报 `running: false`，**中间只有两个 `yield`、没有可交错点**。四个布尔到此为止 —— 它们说得清「引擎没在跑」，说不清「**是谁**把它停了」。

## 3. 改法：先看真实 category，不看那个标志位

```swift
private func configurePlaybackCategoryIfUncontested(_ session: AVAudioSession) throws {
  guard session.category != .playAndRecord else { return }
  try session.setCategory(.playback, mode: .spokenAudio, options: [])
}
```

`DailyReadAudioPlayer.swift:147`，两处调用点（`:157` 的 `configureForBackgroundPlayback`、`:167` 的 `configureAudioSessionForPlayback`）从无条件 `setCategory(.playback, …)` 改为走它。

**为什么读真实 category，而不是读 `DefaultAudioSessionManager.isActive`？**

因为后者是个**永不取假值的判据**。`AudioSessionManaging.swift` 里：

- `private var active = false`（`:22`），只在 `configure(for:)` 里置 `true`（`:56`），只在 `pause()` 里置 `false`（`:70`）；
- **`pause()` 在生产代码里没有调用者** —— 全仓唯一的调用点是 `Tests/FluentWorkCoreTests/Audio/AudioSessionManagingTests.swift:13`。

所以一旦房间起来过，`isActive` 就会**永远报 `true`**。照它判断「房间还活着」会**静默禁掉** Daily Read 的音频 —— 用一个新缺陷换掉一个旧缺陷。真实 category 是唯一说得出「现在归谁」的东西。

**同一个道理也解释了为什么 `describeSession()` 不报 `isActive`**：`AVAudioSession` 只有 `setActive(_:options:)`，**没有** `isActive` getter。硬报就等于伪造。它改用 `sampleRate` 当替身 —— category 与 mode 在 deactivate 之后**仍然保留**，所以「一个已经被关掉的 session」照样报 `playAndRecord`/`voiceChat`，而它的 `sampleRate` 是 **0**。这是 proxy，不是 API；实测正是这样。

## 4. 可观测面：三处诊断，都不是「顺手加的日志」

在真机上，**一行都不执行的失败只能靠这类痕迹归因**。本仓已经付过两次「两侧单测全绿而真机静音」的代价（`70_/08_` §3）。

| 诊断 | 位置 | 它回答什么 |
|---|---|---|
| `captureArmed` 的第 5 个关联值 `session` | `AppDependencies.swift:80-82`；报出点 `SpeechSessionMiddleware.swift:661` | 那四个布尔说「引擎没在跑」，这个说**谁把它拿走了** |
| `LiveAudioEngine.describeSession()` | `:1390`，被 `:655` 与 `:1622` 调用 | category / mode / sampleRate / otherAudio / duckHint 的快照 |
| `session_interrupted_by_system` 埋点 | `SpeechSessionMiddleware.swift:566` | `.interruptedBySystem` 是**唯一能在我们代码之外**停掉引擎的事件，而在此之前它是这一族里**唯一不留痕**的 |

`.interruptedBySystem` 这条埋点的补法值得单说：它在此之前**只派发、不埋点**（`await dispatchBox.dispatch(.speakingRoom(.session(.interruptedBySystem)))`）。所以「被系统中断打断」和「被任何别的东西打断」在日志里长得完全一样 —— **失败按构造不可观测**。

## 5. 测试：可观测那一半的「先红」

按 `AGENTS.md` 的要求，每个修复从一条会失败的测试开始。**本条的这一半做得到** —— 所以做了，而且做了两次变异验证（`24_` §6.2 的手法：钉住的测试必须证明它会咬）。

**变异一：删掉 `session_interrupted_by_system` 埋点**（`SpeechSessionMiddleware.swift:566`）

```
✘ Test systemInterruptionIsVisibleInTheTracker() recorded an issue at
  SpeakingRoomSessionWiringTests.swift:557:19: Expectation failed:
  tracker.events.first { $0.name == "timing_session_interrupted_by_system" }
↳ 系统中断发生了却没有任何 tracker 记录——这正是这次要修的可观测性洞
↳ tracker.events.first { $0.name == "timing_session_interrupted_by_system" } → nil
✘ Test run with 1 test in 0 suites failed after 2.016 seconds with 1 issue.
```

**变异二：删掉 `captureArmed` 的 `session` 键**（`SpeechSessionMiddleware.swift:661`）

```
✘ Test captureDiagnosticsKeepTheirMarkNamesAndPropertyKeys() recorded an issue at
  SpeakingRoomSessionWiringTests.swift:667:13: Expectation failed: hit.properties[key] != nil
↳ 埋点 timing_audio_capture_armed 少了属性键 session——它降级成了一条无法判读的日志
↳ hit.properties[key] → false
↳   hit.properties[key] → nil
✘ Test run with 1 test in 0 suites failed after 0.024 seconds with 1 issue.
```

两次都咬住，失败信息指名道姓。两次变异均已还原，`SpeechSessionMiddleware.swift` 的 sha256 与备份逐字节一致（`8f0f2feb…`）。

**新增的那条测试为什么独立成条、而不是并进 `24_` 那张表**：`.interruptedBySystem` 会**挂起状态机**。并进表里就等于顺带改动了表里其余每一条的到达条件 —— 第一版就是那么写的，`swift test` 上红。所以它单独一条，只做一件事。

## 6. 为什么音频那一半没有「先红」

**因为本仓的测试层级结构上测不到它。**

`configurePlaybackCategoryIfUncontested` 整体在 `#if os(iOS)` 里（`DailyReadAudioPlayer.swift:145-150`），而 `swift test` 跑在 macOS 上（实测 `Target Platform: arm64e-apple-macos14.0`）—— 那段代码在测试进程里**根本不参与编译**。所以「改 category → input route 被拆 → 引擎停」这条因果链，在本仓没有任何测试能复现。

这不是本条的偷懒，是 `80_/03_` §4.5 与 `70_/08_` §3 已经记录的事实：**真机静音与真机 barge-in 那类问题只能靠真机验证**，而那次验证（S0-3）至今未做。

**能覆盖它的只有门禁的第二条**：iOS Debug 构建。那是唯一会编译 `#if os(iOS)` 分支的步骤 —— 见 §8。

## 7. 影响面

- **状态机**：无。`captureArmed` 加的是**关联值**，状态转移未变。
- **协议（线上）**：无。没有任何控制帧改动。
- **音频**：**有，且是本条的目的** —— Daily Read 在房间占用期间不再改 category，因此不再拆掉 input route。
- **发布行为**：无。不加开关；失败模式从「静默静音」变为「Daily Read 的音频让位」，这是契约想要的方向。
- **`captureArmed` 的消费者**：只有埋点通道（`SpeechSessionMiddleware.swift:661`）与测试。加关联值是一次**编译期**破坏 —— 漏改会编译失败，不会静默。
- **回滚**：`git revert` 该提交即可；无数据迁移、无状态遗留。

## 8. 门禁

| 项 | 命令 | 结果 |
|---|---|---|
| 构建（macOS） | `swift build --disable-sandbox` | `Build complete!` |
| 测试 | `swift test --disable-sandbox` | **591 tests / 28 suites** —— 见下方说明 |
| Debug 构建（iOS） | `xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost -configuration Debug -destination 'generic/platform=iOS Simulator' build` | `** BUILD SUCCEEDED **` |

> **测试这一条必须如实交代**：全量跑会红在 `captureDiagnosticsKeepTheirMarkNamesAndPropertyKeys`，但**那条红与本条改动无关，也不是它造成的**。同一台机器上：HEAD（不含本条任何改动）全量连跑 3 次 **1 绿 2 红**；该测试**单跑必绿（0.022s）**。根因是 `waitUntil` 超时 `throw TimeoutError()` 而 `SpeakingRoomSessionWiringTests.swift` 里 **82 处**写成 `try? await waitUntil(…)`，超时被吞掉，测试继续往下走，于是在闸门未开时发 `.speechStarted`/`.speechEnded`，`timing_audio_uplink_turn` 不出现 —— 报错文案却说「埋点不见了」。**一个 1 秒的测试超时伪装成了一条对生产代码的指控。**
>
> 已按 S1-2 / S1-3 单列为一票修（见 `80_/05_` 与后续的 `70_/28_`）。**本条不以「全量绿」作为它的证据**，它的证据是 §5 的两次变异验证 + iOS Debug 构建。

## 9. 未覆盖 / 未决

1. **结构问题没关（S1-10 仍开着）**。本条的修法是**局部的**：Daily Read 学会了让路，但 `AVAudioSession` 依然是「两个实现点」—— `LiveAudioEngine` 走 `AudioSessionManaging`，`DailyReadAudioPlayer` **绕过它**直接碰 `sharedInstance()`。真修法是让后者也注入 `AudioSessionManaging`，或把「谁在占用」变成可查询的真值。**本条不做**：那是接口改动，且它会把 Daily Read 的构造签名改掉，值得单独一票。
2. **`DefaultAudioSessionManager.pause()` 在生产里没有调用者**（只有测试调）。所以 `isActive` 是个**永不取假值的判据**。要么给它找一个真实调用点，要么删掉这个属性 —— **未决**。
3. **`describeSession()` 的 `sampleRate` 是 proxy 而非 API**。实测有效（deactivate 后为 0），但它依赖 Apple 的实现细节，值得在真机验证（S0-3）时一并核对。
4. **Daily Read 让路之后的听感未在真机验证**：`AVPlayer` 在 `.playAndRecord` 下能放，但音量与路由（扬声器 vs 听筒）在真机上是否可接受，**没有测过**。这与 S0-3 是同一批设备验证。
5. **`AppEnvironment.local` 硬编码了某台机器的 LAN IP**（现为 `192.168.2.156`，注释却写「默认 127.0.0.1」，`70_/08_:77` 已点过）。本轮把工作区里的本机调试值（`.181`）**还原掉了**，没有提交 —— 但这个硬编码本身仍未修。

## 10. 顺带：一条被丢弃的 stash

本轮在 iOS 仓清出一条残留 stash（基于 `00c182f`，2026-09-20），是**同一个真机 bug 的上一版尝试**。它与本条方向相反，值得记下来：

- 它在 `startCapture` 路径里塞了「重启引擎 + 重试 keep-alive」；
- 并在失败时 `throw audioSessionConflict(...)`；
- **而它的最后一处改动是把 `captureArmed` 的 `running: engine.isRunning` 换成 `running: runningAfterGuard`，其中 `let runningAfterGuard = true` 是字面量。**

也就是说：它让 `running` **永远报 `true`** —— 而 `captureArmed` 这个埋点存在的全部理由，恰恰是 `running: false` 那个分支（`24_` §2.2）。**它删掉了本条所依赖的那个信号。** 一条假的证据比没有证据更贵：`70_/16_`/`17_` 是「判据从不取真值」，这一条是「**用假值替换了真值，顺手删掉唯一的诊断**」。

已丢弃（`audioSessionConflict` 与 `startCaptureEngine` 在 HEAD 上本来就有，stash 未带来任何 HEAD 与本条都没有的东西）。
