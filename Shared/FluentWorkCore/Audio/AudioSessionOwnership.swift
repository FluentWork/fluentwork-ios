@preconcurrency import AVFoundation
import Foundation
import os

// MARK: - 路线与配置

/// 共享 `AVAudioSession` 要服务的一条路线。
///
/// 三个是**互斥的配置意图**，不是一个优先级列表 —— 选哪条由谁在认领决定，
/// 而「能不能认领」是 `AudioSessionPolicy` 的事。
public enum AudioRoute: String, CaseIterable, Sendable {
    /// 只要采集。**目前没有生产调用方**（发音评测是 V1.1），但它下面那行配置由判据钉着 ——
    /// 否则它就是一条会腐烂的死分支，而腐烂的方式是安静的。
    case capture
    /// 只要播放：每日一读的 AI 朗读（锁屏也要继续）。
    case playback
    /// 采集 + 播放同时：说的房间。
    case fullDuplex
}

public enum AudioSessionCategory: String, CaseIterable, Sendable {
    // 值是 AVFoundation 自己的 `rawValue`，所以适配器能直接构造回去，而这张表
    // 在 **CI 平台（macOS）上也能纯测** —— `AVAudioSession` 本身在 macOS 上不存在。
    case record = "AVAudioSessionCategoryRecord"
    case playback = "AVAudioSessionCategoryPlayback"
    case playAndRecord = "AVAudioSessionCategoryPlayAndRecord"
}

public enum AudioSessionMode: String, CaseIterable, Sendable {
    case measurement = "AVAudioSessionModeMeasurement"
    case spokenAudio = "AVAudioSessionModeSpokenAudio"
    case voiceChat = "AVAudioSessionModeVoiceChat"
}

/// **类别**选项。
///
/// 没有 `rawValue`：`AVAudioSession.CategoryOptions` 是位掩码 OptionSet，
/// 与它之间没有字符串往返，放一条用不到的 rawValue 就是死数据。
/// 与真实选项的绑定由端口里那个 `switch` 承担 —— 编译器检查的，比字符串强。
///
/// ⚠️ 这里**没有** `notifyOthersOnDeactivation`：它是 `setActive` 的选项
/// （`AVAudioSession.SetActiveOptions`），不是类别选项。第一版把它混进来，
/// iOS 编译当场红（`type 'CategoryOptions.Element' has no member ...`）——
/// 那是**腿 2 抓到的**，macOS 的 `swift build` 把这段 `#if os(iOS)` 编译掉了。
public enum AudioSessionOption: CaseIterable, Sendable {
    case allowBluetoothHFP
    case defaultToSpeaker
}

public struct AudioSessionConfiguration: Equatable, Sendable {
    public let category: AudioSessionCategory
    public let mode: AudioSessionMode
    /// 按 `AudioSessionOption.allCases` 顺序排列。集合语义 —— 顺序不携带信息，
    /// 但判据要能逐字比，所以构造时排好。
    public let options: [AudioSessionOption]

    public init(
        category: AudioSessionCategory,
        mode: AudioSessionMode,
        options: [AudioSessionOption]
    ) {
        self.category = category
        self.mode = mode
        self.options = AudioSessionOption.allCases.filter(options.contains)
    }
}

extension AudioRoute {
    /// 这条路线对应的会话配置。
    ///
    /// **这张表是 `FeatureFlags.voiceProcessingCapture` 那条注释的依据**：它写着
    /// 「`.playAndRecord` + `.voiceChat` 由会话主人设定」。
    /// 在 2026-09-29 之前那句话没有任何东西验证 —— 判据现在钉住它。
    public var configuration: AudioSessionConfiguration {
        switch self {
        case .capture:
            .init(category: .record, mode: .measurement, options: [.allowBluetoothHFP])
        case .playback:
            .init(category: .playback, mode: .spokenAudio, options: [])
        case .fullDuplex:
            .init(
                category: .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
        }
    }

    /// 三条路线共用的首选值：上行是 16 kHz 单声道 PCM16，而 20 ms 的 IO buffer 是
    /// 上行分帧与 VAD 尾部判定的共同前提。
    public static let preferredSampleRate: Double = 16_000
    public static let preferredIOBufferDuration: TimeInterval = 0.02
}

// MARK: - 真实会话的可观测面

/// 共享会话此刻**能被观测到**的东西。
///
/// 这一层存在的理由：`AVAudioSession` 暴露 `setActive` 但**没有** getter，
/// 所以「会话活着吗、谁在占着」不能问它，只能从类别（我们是唯一会改类别的人）
/// 与采样率（被 deactivate 的会话报告 **0**）推。**推出来的东西要写在一处** ——
/// 这一票之前它散在三个地方，其中一处是个永不取假的标志位。
public struct AudioSessionSnapshot: Equatable, Sendable {
    /// 系统报告的类别。用**字符串**而不是我们的枚举：系统可能报出我们不建模的类别
    /// （`ambient` / `soloAmbient` / `multiRoute`…），而那些恰恰是「别人占了它」的信号，
    /// 不能因为不在枚举里就丢掉。
    public var category: String
    public var mode: String
    public var sampleRate: Double
    public var otherAudioPlaying: Bool
    public var secondaryAudioShouldBeSilenced: Bool

    public init(
        category: String,
        mode: String,
        sampleRate: Double,
        otherAudioPlaying: Bool,
        secondaryAudioShouldBeSilenced: Bool = false
    ) {
        self.category = category
        self.mode = mode
        self.sampleRate = sampleRate
        self.otherAudioPlaying = otherAudioPlaying
        self.secondaryAudioShouldBeSilenced = secondaryAudioShouldBeSilenced
    }

    /// 把 rawValue 认成我们建模的类别。认不出来 ⇒ `nil`，那本身是信息（别人占着）。
    public var knownCategory: AudioSessionCategory? {
        AudioSessionCategory(rawValue: category)
    }

    /// 活动性的**代理**，不是 API。
    ///
    /// 别把它读成 `isActive`：`AVAudioSession` 没有那个 getter，而自己维护一个标志位
    /// 正是 F6 拆掉的那个东西 —— 一个只在 `configure()` 里被置真的 `active` 标志位，
    /// 而它的「关」那条路径在生产里没有调用者，所以它会**永远**报「房间还活着」，
    /// 照它做判断会静默禁掉每日一读的音频（`meta 70_/27_`）。
    ///
    /// 一个被 deactivate 的会话报告零采样率。**类别与模式在 deactivate 之后存活**，
    /// 所以「类别像采集会话、采样率为 0」是一个真实且可读的状态，不是矛盾。
    public var looksActive: Bool { sampleRate > 0 }

    /// 供真机失败归因的一行。
    ///
    /// 字段表**只有这一份**（之前 `LiveAudioEngine.describeSession()` 自己列了一遍）。
    /// 设备上一次「一行代码都不执行的失败」只能靠这类痕迹归因 —— 本仓为此付过两次
    /// 「两侧单测全绿而真机静音」的代价（`meta 70_/08_` §3），所以它由判据钉住。
    public var telemetrySummary: String {
        "category=\(category) mode=\(mode)"
            + " sampleRate=\(Int(sampleRate)) otherAudio=\(otherAudioPlaying)"
            + " duckHint=\(secondaryAudioShouldBeSilenced)"
    }
}

// MARK: - 谁在占用（派生的真值）

/// 此刻谁占着共享会话。
///
/// 这是本票要的「可查询的真值」：它是**从真实会话派生**的，不是一个被维护的标志位，
/// 所以它不可能与事实脱节。
public enum AudioSessionHolder: Equatable, Sendable {
    /// 本 App 从没认领过。
    case noOne
    /// 本 App 认领着，类别与这条路线一致。
    case claimed(AudioRoute)
    /// 会话上的类别不是本 App 认领的那三个之一 —— 真机上这就是 **App 启动时的系统默认值**。
    ///
    /// **它不是一个独立的「占用者」**：类别是**每进程**的属性，别的 App 改不了我们的会话
    /// （它们只体现为 `otherAudioPlaying`）。而本仓现在只有一条路径会设类别，
    /// 还有一条守卫盯着不许绕过它 ⇒ 认不出的值只可能来自「我们没设过」。
    ///
    /// 第一版把这一档写成「别人占着、于是让路」，判据当场抓出来：那样一来
    /// **每日一读在 App 启动后永远拿不到 `.playback`**（因为一进来看到的就是默认值），
    /// 锁屏播放直接坏掉。名字因此从 `someoneElse` 改成 `notOurClaim` —— 它记的是一条事实，
    /// 不是一个占用者。
    case notOurClaim(category: String)

    /// 认领者对应的路线。`.noOne` / `.notOurClaim` 没有。
    public var route: AudioRoute? {
        guard case .claimed(let route) = self else { return nil }
        return route
    }

    /// **唯一**需要让路的理由：这个占用者用着 input route。
    ///
    /// 换掉一个带输入路线的类别会拆掉那条路线，让正在跑的 `AVAudioEngine` 自己停 ——
    /// 而它一行我们的代码都不执行（2026-09-24 事故）。
    /// 没有输入路线的类别（播放、以及我们没设过的任何值）没有东西可拆，所以是空闲的。
    public var usesTheInputRoute: Bool {
        switch self {
        case .claimed(.capture), .claimed(.fullDuplex): true
        case .claimed(.playback), .noOne, .notOurClaim: false
        }
    }

    /// 遥测用的短名。
    public var label: String {
        switch self {
        case .noOne: "noOne"
        case .claimed(let route): route.rawValue
        case .notOurClaim(let category): "notOurClaim(\(category))"
        }
    }
}

public struct AudioSessionOccupancy: Equatable, Sendable {
    public var holder: AudioSessionHolder
    /// 采样率的代理（见 `AudioSessionSnapshot.looksActive`）。
    public var isLive: Bool
    public var otherAudioPlaying: Bool

    public init(holder: AudioSessionHolder, isLive: Bool, otherAudioPlaying: Bool) {
        self.holder = holder
        self.isLive = isLive
        self.otherAudioPlaying = otherAudioPlaying
    }

    /// **唯一**的推导点。三个消费方（说的房间、每日一读、遥测）都从这里拿，
    /// 这样「谁在占用」不会有两个版本。
    public static func derive(from snapshot: AudioSessionSnapshot) -> AudioSessionOccupancy {
        let holder: AudioSessionHolder
        switch snapshot.knownCategory {
        case .playAndRecord:
            // `.playAndRecord` 与 `.record` 都是「有输入路线」的类别，都是我们认领的。
            // 认领者由类别决定：这两条路线各有唯一的类别（见 `AudioRoute.configuration`）。
            holder = .claimed(.fullDuplex)
        case .record:
            holder = .claimed(.capture)
        case .playback:
            holder = .claimed(.playback)
        case nil where snapshot.category.isEmpty:
            // 空的类别 rawValue **不是**「我们不认识的类别」，是**没有会话**：
            // 非 iOS 上的端口（那里没有 `AVAudioSession`）返回它，iOS 的正常路径不会出现。
            holder = .noOne
        case nil:
            holder = .notOurClaim(category: snapshot.category)
        }
        return AudioSessionOccupancy(
            holder: holder,
            isLive: snapshot.looksActive,
            otherAudioPlaying: snapshot.otherAudioPlaying
        )
    }
}

// MARK: - 策略（纯函数，零 IO）

/// 一次认领会做什么。
public enum AudioSessionClaim: Equatable, Sendable {
    /// 把类别切到这条路线，然后激活。
    case reconfigure(AudioRoute)
    /// **类别不动**，只激活。
    ///
    /// 每日一读会走到这里：`AVPlayer` 在 `.playAndRecord` 下照样能放 ——
    /// 它不需要赢这场争夺，只需要不替对方输掉（`meta 70_/27_`）。
    /// 切走类别会拆掉 input route，让正在跑的 `AVAudioEngine` 自己停，
    /// 而它**一行我们的代码都不执行**，所以 `isRunning` 变 false 时没有任何栈可读。
    case keepCategory(heldBy: AudioSessionHolder)
}

/// 一次归还该做什么。
public enum AudioSessionRelease: Equatable, Sendable {
    case deactivate
    /// 别人还占着 / 一个不持有租约的人来归还 —— **不要** deactivate。
    ///
    /// 这与「认领时不要抢」是同一件事的另一半，而它在 2026-09-29 之前**没人守**：
    /// 每日一读的 `teardown()` 无条件 `setActive(false)`，所以「朗读放完」会把
    /// 正在跑的说的房间一起关掉 —— 同一类静默事故，方向相反。
    case keep(heldBy: AudioSessionHolder)
    /// 类别可以让，但**还有别的租约在册** —— 关掉会把借用者弄哑。
    ///
    /// 与上一档分开是因为「为什么不许关」是两件不同的事：上一档是**类别**被别人占着
    /// （换了会拆 input route），这一档是**别人正在借这个类别用**。合成一档会让
    /// 「谁在占」这个问题的答案变得含混，而含混的答案在这条链路上等于静默失败。
    case keepLeased(by: [AudioRoute])
}

public enum AudioSessionPolicy {
    /// 这条路线能不能认领、认领时要做什么。
    public static func claim(
        for route: AudioRoute,
        given occupancy: AudioSessionOccupancy
    ) -> AudioSessionClaim {
        // 需要 input route 的路线（说的房间、未来的发音评测）**必须**赢：类别被占着时
        // 它们不是「体验差一点」，是根本工作不了。所以它们总是重配，哪怕占用者我们不认识。
        guard route == .playback else { return .reconfigure(route) }

        // 只要播放的路线只在**没有 input route 被占用**时接管。
        //
        // 让路的判据是「换掉它会不会拆掉一条输入路线」，**不是**「我认不认识这个类别」。
        // 后者是这一层最容易写错的地方：认不出的值在真机上就是 App 启动时的系统默认值，
        // 把它当成「别人占着」会让每日一读永远拿不到 `.playback`（锁屏播放坏掉）。
        // 前者只保护真正会被拆坏的东西，而那个集合是 `usesTheInputRoute` 算出来的 ——
        // 将来加路线时，忘了想这件事的后果是判据红，不是静默多一条抢夺路径。
        if occupancy.holder.usesTheInputRoute {
            return .keepCategory(heldBy: occupancy.holder)
        }
        return .reconfigure(.playback)
    }

    /// 归还时能不能 deactivate。
    ///
    /// 三个输入回答三个不同的问题：**我有没有东西可还**（`holdsALease`）、
    /// **这次释放之后名册上还剩谁**（`remainingLeases`，含请求者自己剩下的那几次）、
    /// **类别是不是我们设的**（`occupancy`）。
    public static func release(
        from requester: AudioRoute,
        given occupancy: AudioSessionOccupancy,
        holdsALease: Bool,
        remainingLeases: [AudioRoute]
    ) -> AudioSessionRelease {
        // 一个不持有租约的人不许关掉别人的会话。这条在租约模型之前不可能表达：
        // 那时「谁在占」只能从类别推，而类别答不了「你是不是其中一个使用者」。
        guard holdsALease else { return .keep(heldBy: occupancy.holder) }

        // 名册上还有人（别人，或**自己没还完的那几次**）：关掉会把在用的人一起弄哑。
        // 「自己还欠着一次」也必须走这一支：租约是计数的，认领两次就得归还两次。
        guard remainingLeases.isEmpty else { return .keepLeased(by: remainingLeases) }

        // 只剩自己了，但类别不是我们设的（真机上就是 App 启动时的系统默认值）：
        // 没有东西可以归还，而关掉一个不属于我们的会话既没理由也没好处。
        switch occupancy.holder {
        case .notOurClaim:
            return .keep(heldBy: occupancy.holder)
        case .noOne, .claimed:
            return .deactivate
        }
    }
}

// MARK: - 端口（唯一碰 AVAudioSession 的地方）

/// 对真实 `AVAudioSession` 的最小操作面。
///
/// 抽成端口是为了让**判据不碰真实音频会话**：碰了就会改进程的会话，
/// 在 CI 上还要硬件。所以 `AudioSessionPolicy` 是纯函数，而这里只负责「应用」。
public protocol AudioSessionPorting: Sendable {
    func snapshot() -> AudioSessionSnapshot
    func apply(_ configuration: AudioSessionConfiguration) throws
    func setActive(_ active: Bool) throws
}

/// 生产者实现。**本仓唯一**配置共享 `AVAudioSession` 的文件（守卫见
/// `Tests/.../Audio/AudioSessionOwnershipGuardTests.swift`）。
public final class SharedAudioSessionPort: AudioSessionPorting {

    public init() {}

    public func snapshot() -> AudioSessionSnapshot {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return AudioSessionSnapshot(
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            sampleRate: session.sampleRate,
            otherAudioPlaying: session.isOtherAudioPlaying,
            secondaryAudioShouldBeSilenced: session.secondaryAudioShouldBeSilencedHint
        )
        #else
        // macOS 没有 `AVAudioSession`。返回一个「没被认领」的快照，让上层逻辑照常跑。
        return AudioSessionSnapshot(
            category: "",
            mode: "",
            sampleRate: 0,
            otherAudioPlaying: false
        )
        #endif
    }

    public func apply(_ configuration: AudioSessionConfiguration) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // 写方向用 `switch` 而不是 rawValue 往返：`AVAudioSession.Category(rawValue:)`
        // **不是** failable 的，所以一个拼错的 rawValue 会安静地造出一个未知类别
        // （而类别正是会拆掉 input route 的那个东西）。`switch` 是编译器检查的。
        // 读方向仍然用 rawValue —— 那边本来就只能拿到字符串。
        let category: AVAudioSession.Category
        switch configuration.category {
        case .record: category = .record
        case .playback: category = .playback
        case .playAndRecord: category = .playAndRecord
        }
        let mode: AVAudioSession.Mode
        switch configuration.mode {
        case .measurement: mode = .measurement
        case .spokenAudio: mode = .spokenAudio
        case .voiceChat: mode = .voiceChat
        }
        var options: AVAudioSession.CategoryOptions = []
        for option in configuration.options {
            switch option {
            case .allowBluetoothHFP: options.insert(.allowBluetoothHFP)
            case .defaultToSpeaker: options.insert(.defaultToSpeaker)
            }
        }
        try session.setCategory(category, mode: mode, options: options)
        // 三条路线共用（上行是 16 kHz 单声道 PCM16）。
        try session.setPreferredSampleRate(AudioRoute.preferredSampleRate)
        try session.setPreferredIOBufferDuration(AudioRoute.preferredIOBufferDuration)
        #endif
    }

    public func setActive(_ active: Bool) throws {
        #if os(iOS)
        // 反激活时告诉系统「我们不用了」—— 这是 `SetActiveOptions`，不是类别选项，
        // 所以它不出现在 `AudioSessionOption` 里。
        try AVAudioSession.sharedInstance().setActive(
            active,
            options: active ? [] : [.notifyOthersOnDeactivation]
        )
        #else
        _ = active
        #endif
    }
}

// MARK: - 主人

/// 共享 `AVAudioSession` 的认领面。
public protocol AudioSessionOwning: Sendable {
    /// 认领会话给这条路线。返回**实际做了什么** —— 类别可能没被改（见 `AudioSessionClaim`）。
    ///
    /// 认领是**计数**的：同一条路线认领两次就要归还两次。
    @discardableResult
    func claim(_ route: AudioRoute) throws -> AudioSessionClaim
    /// 归还一次认领。**只有**当它是最后一个在册的租约、且类别是我们设的时，才会 deactivate。
    ///
    /// 不持有租约的归还是一句空话：它既不改名册，也不许关掉别人的会话。
    @discardableResult
    func release(from requester: AudioRoute) throws -> AudioSessionRelease
    /// 「谁占了类别」的真值 —— 从真实会话派生。
    ///
    /// 注意它**不回答**「谁在借」：那件事记在租约里，见 `SharedAudioSessionOwner`。
    func occupancy() -> AudioSessionOccupancy
}

/// 唯一的实现：策略 + 端口 + **租约名册**。
///
/// ## 为什么这里有一份状态，而本票主张「占用从真实会话派生」
///
/// 因为这是两个不同的问题，而它们能不能派生**不一样**：
///
/// | 问题 | 能不能派生 | 谁回答 |
/// |---|---|---|
/// | **类别归谁**（动类别会不会拆掉 input route） | **能** —— 类别是进程级属性，而进程内只有我们写它 | `AudioSessionOccupancy.derive(from:)`（零状态） |
/// | **谁在用**（能不能 deactivate） | **不能** —— `AVAudioSession` 里没有「谁认领过」这个信息 | 租约名册（本类） |
///
/// 具体到那个把模型逼出来的场景：说的房间占着 `.playAndRecord`，每日一读借它播（`keepCategory`，
/// 只激活不切类别 —— 那是对的）。此时**类别上一点痕迹都没有**：占用者看起来还是房间，
/// 而房间收尾归还时会判定「是我自己占着」→ `setActive(false)` → 正在播的朗读当场静音。
///
/// 所以：**类别决策照旧从真实会话派生**（这一半仍然零状态、不可能与事实脱节），
/// 「谁在用」记在租约里。别把这两件事混起来 —— 混起来的后果是其中一个必然出错。
public final class SharedAudioSessionOwner: AudioSessionOwning, @unchecked Sendable {
    private struct State {
        /// 路线 → 在册次数。计数而不是集合：同一条路线可以认领两次（重试、或两个入口）。
        var leases: [AudioRoute: Int] = [:]
    }

    private let port: any AudioSessionPorting
    /// `setCategory` / `setActive` 必须串行：说的房间与每日一读在不同的线程上认领
    /// **同一个进程级对象**。用锁而不是 `DispatchQueue.sync` —— 后者正是 `AGENTS.md`
    /// 的并发口径里禁掉的形状（把队列当锁）。
    ///
    /// 锁护的是**两件**事，而且缺一不可：会话的配置，以及租约名册。
    /// 只护配置的话，「读快照 → 做决策 → 写名册」这三步会被并发插队，而租约名册
    /// 一旦被两个线程同时读写，它自己就是一个数据竞争。
    private let gate = OSAllocatedUnfairLock(initialState: State())

    public init(port: any AudioSessionPorting = SharedAudioSessionPort()) {
        self.port = port
    }

    public func occupancy() -> AudioSessionOccupancy {
        AudioSessionOccupancy.derive(from: port.snapshot())
    }

    @discardableResult
    public func claim(_ route: AudioRoute) throws -> AudioSessionClaim {
        try gate.withLock { state in
            // 决策读的是**调用那一刻**的真实会话，而不是上一次认领留下的印象。
            // 它在锁**内**：否则两个并发认领会拿同一份陈旧快照各做各的决策，
            // 后进锁的那个按陈旧决策去动类别 —— 锁就白加了（2026-09-24 那条路依然可达）。
            let decision = AudioSessionPolicy.claim(for: route, given: occupancy())
            if case .reconfigure(let target) = decision {
                // 两个阶段各自包一层：失败的**哪一步**与系统的 domain+code 一样重要。
                // 之前 `apply` 的错是原样抛出去的（连 `AudioEngineError` 都不是），
                // 中间件那条 `catch let error as AudioEngineError` 捞不到它，
                // 于是用户读到 NSError 桥接的那句无信息的话。
                do {
                    try port.apply(target.configuration)
                } catch {
                    throw AudioEngineError.audioSessionClaimFailed(
                        AudioSessionClaimFailure(stage: .configure, error: error)
                    )
                }
            }
            do {
                try port.setActive(true)
            } catch {
                throw AudioEngineError.audioSessionClaimFailed(
                    AudioSessionClaimFailure(stage: .activate, error: error)
                )
            }
            state.leases[route, default: 0] += 1
            return decision
        }
    }

    @discardableResult
    public func release(from requester: AudioRoute) throws -> AudioSessionRelease {
        try gate.withLock { state in
            let held = state.leases[requester] ?? 0
            if held > 1 {
                state.leases[requester] = held - 1
            } else {
                state.leases[requester] = nil
            }
            // 释放之后**还在册**的路线。同一个请求者如果还欠着一次租约，那条也在册 ——
            // 所以它不是「别人」，而是「还没还完的自己」，两者都不许 deactivate。
            let remaining = state.leases.keys.sorted { $0.rawValue < $1.rawValue }
            let decision = AudioSessionPolicy.release(
                from: requester,
                given: occupancy(),
                holdsALease: held > 0,
                remainingLeases: remaining
            )
            if case .deactivate = decision {
                try port.setActive(false)
            }
            return decision
        }
    }
}
