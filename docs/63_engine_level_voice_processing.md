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

## 4. 顺序上的两条硬约束

**① `attemptEnable` 必须按引擎状态给，`startCapture()` 也不例外。**

最初这里写死 `true`。那是个真 bug：`startCapture()` 不是只有「第一个碰引擎的人」会调——播放帧可以经 `startPlaybackIfNeeded()` 把引擎拉起来，之后重试 `startCapture()` 就会撞上一个**正在运行**的引擎。而「在运行的引擎上切换 VP」抛的是 `AVAEInternal … required condition is false`，是 `NSException`，**`do/catch` 看不见**。就是 F12–F16 那一类。

所以默认实现里 `setVoiceProcessingEnabled` 同时包了 `do/catch`（Swift 错误）与 `FWTryCatch`（ObjC 抛出）——**两种失败形态，两个机制，缺一不可**。

**② enable 必须在任何格式读取之前。** 见 §2.3。

## 5. 明确否决 / 未做

- **不在 `reconfigureForRouteChange` 里切换 VP。** 切换需要 `engine.stop()`，而路由变化可能发生在 AI 正说话时——为了一个路由事件把用户欠着的那句回答掐掉不值得。只改格式来源与重装 tap（且只有格式真的变了才重装）。
- **不做「关闭」路径。** `voiceProcessingRequested == false` 而节点仍开着（只能由运行时改 flag 造成，而 `setLocalOverride` 在生产零调用方）时，回读会给出一致的格式，链是对的；只是 flag 的语义不再等价于节点状态。**登记为未做**，免得有人以为 flag 关就一定能关掉单元。
- **`AudioEngineError` 不 conform `LocalizedError`，本次不改。** middleware 用 `error.localizedDescription`，所以本票新加的格式断言即使抛出，用户看到的也是泛化的 "The operation couldn't be completed. (FluentWorkCore.AudioEngineError error 0.)"。一个以「把静默失败变响亮」为目的的守卫喊出来的话看不懂——但修它要**顺带改掉 `audioSessionConflict` 既有的用户可见文案**（变成一句英文的"关掉其他音频 App"），本产品是中文的，英文文案是否可接受属于产品决定。
- **不动 `attachPlayerIfNeeded` 的 connect 格式**（16 kHz mono Int16 进 mixer 是源节点自己的格式，引擎会重采样，F16 以来未崩过）；也**没有**给它加 `FWTryCatch`——那条路抛出的概率是推测的，而它的失败分支走 `.failed`，会**终止 middleware 的音频事件泵**（`docs/49` 的 `OnceFlag`，全进程不再重启），把一个会话的播放问题变成之后每个会话都静默。代价不对称，所以不动。
- **不动播放入口那些既有的 `.failed`**（F16 的测试断言着它们）。但要知道：**任何** `.failed` 都会结束那个泵，本票没有改变这一点。

## 6. 测试

7 条，全部密闭、不碰音频硬件（`docs/19` §4.2）。

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

### 门禁

```bash
swift test          # 473 tests passed  (466 + 7)
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
