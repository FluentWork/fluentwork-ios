# 引擎级 AEC：开关与格式链必须一起改

**日期**：2026-09-11
**状态**：**代码与测试已齐，未真机验证。** AEC 是否达标只有真机能回答（模拟器既没回声也没 VPIO），所以本票交付的是**机制**，结论待 `docs/62` 的 T4。flag **默认关**，T4 通过后才翻。
**对应**：meta `77_` **P0-2**

## 1. 为什么

台账 `77_` §3.2 说 AEC 很可能**没真正生效**，因为两套 API 被混为一谈：

| API | 层 | 改前 |
|---|---|---|
| `AVAudioSession` category `.playAndRecord` + mode `.voiceChat` | **会话级** | 已配（`AudioSessionManaging.swift:41`）|
| `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` | **引擎级** | **全仓零出现** |

自建 `AVAudioEngine` 图里起决定作用的是后者。本票把它接上。

顺带修正两处**既有文档的断言**：`docs/37:60` 与 `docs/38:319` 都写着「会话 category 是 `.playAndRecord` + `.voiceChat`（**系统 AEC**）」——把会话级配置直接当成了 AEC 已生效。本票就是检验那句话的。**在本票真机验证之前，那两处不应被读作已确认。**

## 2. 查证到的三件事（决定了改法）

### 2.1 VPIO 不是滤波器，是一个双工 I/O 单元

在输入节点上开启它会：切到 `kAudioUnitSubType_VoiceProcessingIO`；**同时让输出节点进入 VP 模式**（播放因此成为 AEC 的参考信号——这正是 AEC 成立的原因）；**改变输入节点格式**；**只能在引擎停止时开关**；且输入节点的输出格式与输出节点的输入格式必须一致。

### 2.2 多声道的**默认映射是静音**，不是你以为的 downmix

开启后输入节点实测常见 **多声道 deinterleaved Float32**（3/7/9 声道），其中只有**第 0 声道是人声**，其余是回声计算用的元数据。

台账 §3.2 只说了「格式会变」。变到哪去、以及**不处理会怎样**，是落地时才测出来的：

```
多声道 → 单声道 的转换器，channelMap 默认值是 [-1]
```

`AVAudioConverter` 的定义里**负数表示该输出声道不取任何输入**，即**静音**。所以不设 `channelMap` 的后果**不是送上去的声音被污染，而是上行是空的** —— 而这条链**不抛任何错**：格式合法、转换器构造成功、tap 装得上，然后每一块都在 `processInput` 的 guard 里被丢掉。

这与 2.3 是同一种形状，只是低了一层。测试把默认值钉住了（见 §6）。

### 2.3 先读格式、后开开关 —— 读到的是旧格式，且不抛错

开启**就是**改变格式的那一步。分两步写的调用方读到的是处理前的格式，于是转换器和 tap 都建在一个不会到来的流上。同样不抛错。

所以「开启」和「读格式」在本票里被合成**一个操作**（`prepareCaptureNode`），不是一个调用点上的纪律问题。

## 3. 改法

`Shared/FluentWorkCore/Services/LiveAudioEngine.swift` 是主体。

1. **`prepareCaptureNode(_:attemptEnable:)`** —— 开启 + 读回格式，一个操作。它先问节点 `isVoiceProcessingEnabled`（**节点的事实**），再决定要不要开，最后按**回读结果**决定 tap 用哪个格式。
2. **读回，不读意图。** `voiceProcessingActive` 来自 `isVoiceProcessingEnabled`，不是来自「我们请求了、且没抛错」。这两者不等价：开启会同时作用于两个 I/O 节点、且可能**上一个会话就已经开着**，所以「调用了没报错」推不出「单元已生效」。日志要说的是后者。
3. **`captureFormat(input:processedOutput:voiceProcessingActive:)`** —— 纯静态。VP 生效取 `outputFormat(forBus: 0)`，否则取 `inputFormat(forBus: 0)`（**与改前逐字节一致**，这是回退路径不能变的地方）；处理后的格式不可用则回落。
4. **转换器构造改成 guard + `throw invalidFormat`。** 旧代码把 `AVAudioConverter(from:to:)` 的返回值**不检查地**存进可选的 `self.converter`——构造失败 = 永久静默采集，没有任何东西看得见。台账要求「和 `convertToPCM16` 的格式断言一起改」，具体形态就是这一行。
5. **`channelMap = [0]`**（仅当 `channelCount > 1`），理由见 §2.2。
6. **`installTap` 包 `FWTryCatch`。** 这是本特性的**已知崩溃点**：`CreateRecordingTap: (IsFormatSampleRateAndChannelCountValid(format))`，抛出的是 `NSException`。第 3、4 条是让它不发生的；这一条是万一还是发生了别把进程带走。
7. **`reconfigureForRouteChange()`** 走同一套解析。它可能在**引擎运行中**执行，所以重开被 `!engine.isRunning` 挡住——**路由变化不是开关的时机**。

### 为什么是 feature flag 而不是常量

`AppFeatureFlag.voiceProcessing`，**不进 `firstWave`（默认关）**。middleware 按 flag 下发意图、引擎在 `startCapture()` 建图时应用——**照抄 `voiceVadAuto` → `setSpeechBoundaryMode` 那条路**（`:926`）。

默认关是刻意的：VPIO 带来多声道路径与「输出节点进 VP 模式」，两条都没在真机上跑过；在 T4 给结论前默认开，等于把未验证的变更推给用户，而它不达标时的现象（自激）恰好就是 P0-2 要消除的那个。代价写在 T4 里：**T4 需要一个把 flag 打开的构建**。

## 3.1 差点就这么发出去的：extension-only 方法到不了引擎

第一版把 `setVoiceProcessingEnabled` **只加进了 `AudioEngineProtocol` 的 extension，没加进 protocol 自己的 requirement 列表**。其余四个同类方法（`setSpeechBoundaryMode` / `beginManualSpeech` / `endManualSpeech` / `reconfigureForRouteChange`）都在 requirement 列表里，加的时候漏了这一个。

后果不是编译错误，是**整个特性死掉**：

> 只在 extension 里声明的方法，通过 `any AudioEngineProtocol` 调用时是**静态派发**的。

中间件持有的正是 `any AudioEngineProtocol`。所以跑的是 extension 里那个空实现，`LiveAudioEngine.setVoiceProcessingEnabled` **一次都不会被调用** —— flag 永远到不了音频路径，真机上 T4 会看到「开关是关的」，而**所有直接拿具体类型 `LiveAudioEngine` 写的单测照样全绿**。

抓它的是那条**接线测试**（middleware 那条），不是引擎侧的任何测试 —— 引擎侧的 7 条全绿，因为它们构造的是具体类型。这条正是「测试替身与生产行为不同」的那一类：替身和真实现都实现了这个方法，谁都没被调到。

修法是把 `func setVoiceProcessingEnabled(_ enabled: Bool) async` 加回 requirement 列表（extension 里保留默认实现，所以 5 个 conformer 一个都不用改）。

## 3.2 一轮对抗性评审改掉了什么

落地后跑了 `code-review`（目标 `ecfaf7d`，14 条）。它**独立**复现了 §3.1 那条（同一处、同一后果），另外 5 条是真的，已改：

| 改了什么 | 为什么 |
|---|---|
| `reconfigureForRouteChange` 的 `installTap` 也包 `FWTryCatch` | 我包了 `startCapture` 那条、**漏了这条** —— 而这条才是运行中会话 + 设备真的换了的那条路。同一个已知崩溃点，一半有兜底等于没有 |
| `captureFormat` 取消 `?? usable(input)` 回落 | 单元开着时原始格式描述的是**已经不存在的流**；回落等于把那个 abort 又请回来，而且报告还说 `on`。**这条与 §2.2 是同一类错误的两个位置** |
| `startCapture` 里可失败的步骤全部挪到拆旧 tap **之前** | 旧顺序下转换器守卫一抛，`hasInstalledTap` 就留在「有 tap」而 tap 已经没了 —— 路由变化会据此给一个死会话重装 tap，`stopCapture()` 会对不存在的 tap 调 `removeTap` |
| 报告区分「关」与「想开但没开成」 | 引擎已在运行时 `startCapture` 会**跳过** enable，而旧的报告只写 `off` —— 与 flag 关着一字不差。按 T4 的规矩就会把人打发去改 `firstWave` 重新构建，而真正的原因是引擎在跑。**A/B 会悄悄变成「关 vs 关」** |
| `reconfigureForRouteChange` **不再尝试** enable，且只在格式/状态真的变了才重装 tap | 代码此前与提交信息和本文档说的**相反**（文档说不切换，代码切了）。而且切换落在旧 tap 还装着的时候 |
| `_testConvertToPCM16` 补上 `channelMap` | 它此前**不建模生产链**：多声道源的默认映射是静音，而这个 hook 不设映射 —— 于是「tap 链正常」是对一片生产会变成空上行的输入说的 |

另有两条**只改文档、不改代码**：§5 里「不做关闭路径」的理由（见该条下的更正框），以及 §6 里「全部密闭」的过头说法（见该节的更正）。

> 一条**没改**但值得记：`setVoiceProcessingEnabled` 的 extension 默认空实现**保留着**。评审指出「任何漏写这个方法的 conformer 都会静默空转，`PlaceholderAudioEngine` 今天就是」。但那是默认实现这个机制的固有代价，与其余四个同类方法一致；**§3.1 的病根是它没进 requirement 列表，不是它有默认实现**。加了 requirement 之后，默认实现只会作为真正的默认被动态派发到 —— 对 `PlaceholderAudioEngine` 而言那正是想要的。

## 4. 顺序上的两条硬约束

**① `attemptEnable` 必须按引擎状态给，`startCapture()` 也不例外。**

最初这里写死 `true`。那是个真 bug：`startCapture()` 不是只有「第一个碰引擎的人」会调——播放帧可以经 `startPlaybackIfNeeded()` 把引擎拉起来，之后重试 `startCapture()` 就会撞上一个**正在运行**的引擎。而「在运行的引擎上切换 VP」抛的是 `AVAEInternal … required condition is false`，是 `NSException`，**`do/catch` 看不见**。就是 F12–F16 那一类。

所以默认实现里 `setVoiceProcessingEnabled` 同时包了 `do/catch`（Swift 错误）与 `FWTryCatch`（ObjC 抛出）——**两种失败形态，两个机制，缺一不可**。

**② enable 必须在任何格式读取之前。** 见 §2.3。

## 5. 明确否决 / 未做

- **不在 `reconfigureForRouteChange` 里切换 VP。** 切换需要 `engine.stop()`，而路由变化可能发生在 AI 正说话时——为了一个路由事件把用户欠着的那句回答掐掉不值得。而且切换会落在**旧 tap 仍装在 bus 0 上**的时刻（拆装在同一条路径上），把节点的产出格式换到那个 tap 底下。**什么都不用牺牲**：状态是回读的，路由变化丢掉的单元给出原始格式、活下来的给出处理格式，两种都自洽。
- **不做「关闭」路径。** `voiceProcessingRequested == false` 而节点仍开着时，回读给出一致的格式，链是对的；只是 flag 的语义不再等价于节点状态。**登记为未做**，免得有人以为 flag 关就一定能关掉单元。
  > ⚠️ **第一版的理由是错的**：原文写「只能由运行时改 flag 造成，而 `setLocalOverride` 在生产零调用方」。评审指出**那不是唯一的通道** —— `.lifecycle(.bootstrapSucceeded)` 会把 `state.featureFlags.snapshot` 直接写成解析器给的那份（`AppReducer.swift:114`）。核对后：今天仍不可达，因为 `makeFirstWaveResolver()` 只注册了 `DebugProvider` 与 `LocalProvider`，**没有远端 provider**，所以那份 snapshot 只能等于 `firstWave`。但**理由是「今天没有远端通道」，不是「没有通道」** —— 接上远端 flag 的那天，这条就从「不可达」变成「可达」。留此存档。
- **`AudioEngineError` 不 conform `LocalizedError`，本次不改** —— 但**载荷现在进日志**。middleware 用 `error.localizedDescription`，所以本票新加的格式断言抛出时，用户看到的仍是泛化的 "The operation couldn't be completed. (FluentWorkCore.AudioEngineError error 0.)"。改文案要**顺带改掉 `audioSessionConflict` 既有的英文文案**，中文产品里是否可接受属于产品决定。但「用户看到什么」与「日志里有什么」是两件事：`createSession` 的 catch 现在单独接住 `AudioEngineError`，把关联值原样 `timings.mark` 出去。否则一次死在格式守卫上的真机会话，日志里什么线索都没有 —— 那正是这些守卫要消除的失败形态。
- **不动 `attachPlayerIfNeeded` 的 connect 格式**（16 kHz mono Int16 进 mixer 是源节点自己的格式，引擎会重采样，F16 以来未崩过）；也**没有**给它加 `FWTryCatch`——那条路抛出的概率是推测的，而它的失败分支走 `.failed`，会**终止 middleware 的音频事件泵**（`docs/49` 的 `OnceFlag`，全进程不再重启），把一个会话的播放问题变成之后每个会话都静默。代价不对称，所以不动。
- **不动播放入口那些既有的 `.failed`**（F16 的测试断言着它们）。但要知道：**任何** `.failed` 都会结束那个泵，本票没有改变这一点。

## 6. 测试

12 条：**引擎侧 8 条**（格式决策 + 顺序 + 拒绝 + 报告措辞 + 多声道端到端）+ **中间件侧 2 条**（flag → 引擎的接线）+ **flag 默认值 1 条** + 既有的声道映射 1 条。

中间件那 2 条不是凑数：§3.1 那个 bug 只有它们能抓到。**引擎侧测试全绿而生产路径是死的**，这是本票最值得记的一课 —— 只测具体类型，测不出经过存在类型的调用。

### ⚠️ 但「全部密闭」是**过头的话**，这里更正

其中 3 条（`startCaptureEnablesVoiceProcessingBeforeReadingTheInputFormat` / `...LeavesVoiceProcessingAlone...` / `aRefusedVoiceProcessingUnit...`）调的是**真实的 `startCapture()`**，它们「不碰硬件」靠的是 `docs/19` §4.2 第 5 项**明令禁止**的那件事 —— 依赖当前机器有没有音频设备：

- **CI 上**：`inputFormat` 是 0Hz/0ch，`startCapture()` 在格式守卫处停住，测的确实只是「守卫之前发生过什么」。
- **一台有麦克风的开发机上**：守卫**通过**，于是这三条会真的 `installTap` 到真实输入节点并调真实 `engine.start()`，而且**没有一条调 `stopCapture()`** —— 引擎会一直开着。

这个形状是**继承来的**：既有的 `liveAudioEngineStartCaptureKeepsTheConfiguredBoundaryMode` 就是同样的写法（`PermissiveAudioSessionManager` + `try? startCapture()`）。本票照抄了它，没有让它变好。**登记为已知局限**，不假装是密闭的。

真正完全密闭的是另外那些：纯静态函数、采样器 seam、中间件接线、flag 默认值断言。

CI 的关键约束：`swift test` 跑在没有音频输入设备的 macOS runner 上，`inputFormat` 是 0Hz/0ch，所以 `startCapture()` **在格式守卫处就停住**，之后一行都不执行。**不能靠 `try? startCapture()` 去够被测代码**——仓里既有的那条 `startCapture()` 测试在 CI 里就是空的。所以本票的断言分两类：

1. **纯静态函数**（`captureFormat` / `captureChannelMap` / `voiceProcessingReport`）：合成 `AVAudioFormat`，完全可测，是本票的主力。
2. **「抛错前做过的事」**：照 `didConfigureFullDuplex` 那条既有断言的形状——即使 `startCapture()` 随后因设备原因抛错，断言在守卫**之前**发生的调用。

多声道格式要用**离散声道布局**构造：`AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` 在 2 声道以上返回 `nil`。

### 红验证

三次，各自红的都是预料的那条：

**① 去掉 `channelMap = [0]`** ——

```
✘ Test captureChannelMapTakesOnlyTheMicrophoneChannel() recorded an issue at
  LiveAudioEngineTests.swift:534:5: Expectation failed:
  (multiConverter.channelMap.map(\.intValue) → [-1]) == [0]
```

这条同时把 §2.2 的默认值钉住了：`[-1]` 就是静音。

**② 把 `captureFormat` 改回「永远取 input」**（即改前的行为）——

```
✘ Test captureFormatUsesTheProcessedStreamOnlyWhenVoiceProcessingIsOn() recorded an issue at
  LiveAudioEngineTests.swift:472:5: Expectation failed: (LiveAudioEngine.captureFormat(
```

**③ 不发出 enable** ——

```
✘ Test startCaptureEnablesVoiceProcessingBeforeReadingTheInputFormat() recorded an issue at
  LiveAudioEngineTests.swift:573:5: Expectation failed: (recorder.calls → 0) == 1
```

第 ③ 条是评审**质疑过强度**的那条（它证的是「enable 在格式守卫之前被调用」，不是「enable 在格式读取之前」）。红验证确认它有牙：去掉调用就红，且红在 `recorder.calls` 上。

**④ 把 `setVoiceProcessingEnabled` 从 requirement 列表拿掉、只留在 extension 里**（即 §3.1 那个 bug 的原状）——

```
✘ Test sessionStartPassesTheVoiceProcessingFlagToTheEngine() recorded an issue at
  SpeechSessionMiddlewareTests.swift:1600:25: Issue recorded
↳ The engine was never told about voice processing. Check that
  `setVoiceProcessingEnabled` is a requirement of `AudioEngineProtocol`, not only a
  defaulted extension method — extension-only methods are dispatched statically
  through the existential and never reach the real engine.
```

这条的失败信息是刻意写长的：`waitUntil` 超时本身只会给一个 `TimeoutError`，说不清任何事情，而这里的成因非常具体、而且**已经发生过一次**。

**⑤ 让 `_testConvertToPCM16` 不设 `channelMap`**（即它改前的样子）——

```
✘ Test multiChannelInputReachesTheTapChainAsAudioNotSilence() recorded an issue at
  LiveAudioEngineTests.swift:598:5: Expectation failed: (peak → 0) > (1_000 → 1000)
```

`peak` **恰好是 0**。§2.2 那条「默认映射是静音，不是 downmix」到这里才算真的证完：前面只是断言映射值是 `[-1]`，这条是把它**跑过一遍 tap 链**，证明那一头出来的是空的上行。

**⑥ 把 `captureFormat` 改回 `?? usable(input)`** ——

```
✘ Test captureFormatRefusesRatherThanFallingBackToTheRawInputWhileVoiceProcessingIsOn() recorded an issue
```

### 门禁

```bash
swift test          # 478 tests passed  (466 + 12)
xcodebuild -project FluentWorkHost.xcodeproj -scheme FluentWorkHost \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build   # BUILD SUCCEEDED
```

### exception（按 AGENTS.md 要求逐条说明）

本票属于 **device-only**：机制用替身复现（注入 seam + 纯函数），**结论待真机确认**。具体是哪些断言够不到哪里：

- 真机上「开关是否真的让 AEC 生效」没法在 `swift test` 里问——那要有回声的物理环境。
- 3、4、5、6 条都在格式守卫**之后**，CI 永远走不到；它们的正确性由「纯函数测试 + 一处薄调用点」承担，不是由端到端测试承担。
- `installTap` 与 `engine.start()` 的失败分支没有 seam，无法在 CI 触发。

## 7. 真机：本票唯一的结论来源

`docs/62` 的 **T4** 已经改成四步（先改一行把 flag 打开 → 确认日志里开关生效 → 再判 AEC → 不通过走半双工退路）。两点补充：

1. **先看 `[Tracker] timing_audio_voice_processing` 那行。**
   `on, tap=48000Hz/1ch` / `on, alreadyOn, …` / `off, …` / `unavailable: …` —— **开关没生效时 T4 的结论不成立**，先修开关再判 AEC。这一行是本票为 T4 专门加的：没有它，「AEC 不行」与「AEC 根本没开」在真机上完全同形。
2. **它是在 `engine.start()` 之前发出的**（故意的：会话若在启动时死掉，日志里仍留下开关状态）。所以它证明的是**开关状态**，不是「这个会话跑起来了」。

⚠️ **一项会移动既有基线的副作用**：VP 默认带 AGC，而 VAD 阈值 `speechThreshold = 0.015` 是按**原始麦克风能量**标定的。增益后的静音可能越过它 —— `autoVAD` 下表现为幻影 `speechStarted`，`tapToStart` 下表现为 8 秒后自动提交。另有播放侧：VPIO 会同时处理输出节点，声音更小、更带宽受限。**这两条都没有动**（不盲调），但 `docs/62` 的 **T1 是听感测试，它的基线会跟着变**。

> 改前那两处文档说「会话即系统 AEC」。改后本票说「引擎级开关接上了，但**效果未验**」——
> 这两句话的距离，就是 T4 要跑的那一趟。**在它跑完之前，本票的成果是「开关不再缺失」，不是「回声被消掉了」。**
