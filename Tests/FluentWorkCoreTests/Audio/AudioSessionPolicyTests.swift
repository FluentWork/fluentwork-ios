import Foundation
import Testing

@testable import FluentWorkCore

/// 共享 `AVAudioSession` 的**占用真值**与**策略**（F6 = `meta iOS-S1-10`）。
///
/// ## 这一层要防的是什么
///
/// `AVAudioSession` 是进程级单例，而本仓有两个组件要按不同方式用它：说的房间要
/// `.playAndRecord` + `.voiceChat`（采集），每日一读要 `.playback`（锁屏继续播）。
///
/// 2026-09-24 真机事故（`meta 70_/27_`）：每日一读为了锁屏继续播，把共享会话切成
/// `.playback`，**拆掉了 input route**，正在跑的 `AVAudioEngine` 于是自己停了 ——
/// 而它**一行我们的代码都不执行**，所以 `isRunning` 变 false 时没有任何栈可读。
/// 练习会话卡在 `.connecting` 直到 10s 看门狗失败。
///
/// 当时的修法是局部的（切之前先读真实 category）。结构问题留着，因为
/// **「谁在占用」没有可查询的真值**：唯一像答案的东西是一个 `isActive` 标志位，
/// 而它读的标志位只在 `configure()` 里置真、`pause()` 在生产里没有调用者 ⇒
/// 它会**永远**报「房间还活着」。
///
/// 所以这一票把占用变成**派生值**：类别（我们是唯一改它的人）+ 采样率（活动性的代理，
/// 因为 `AVAudioSession` 没有 `isActive` getter）。判据因此是纯函数级的 ——
/// 它们在 CI 上跑，不需要音频硬件。
@Suite struct AudioSessionPolicyTests {

    // MARK: - 路线 → 配置（那张被注释引用、却没人验的表）

    /// `FeatureFlags.voiceProcessingCapture` 的注释写着：跟引擎级的
    /// `setVoiceProcessingEnabled` 不是同一个开关，那个由「会话级的
    /// `.playAndRecord` + `.voiceChat`」负责 —— 当时那句话点名的是一个具体的类。
    ///
    /// 那个类已经随 F6 被 `SharedAudioSessionOwner` 取代，而注释里点名的**表本身**
    /// 在 2026-09-29 之前**没有任何东西验证**。这条钉住它。
    @Test func everyRouteHasTheConfigurationTheFlagCommentClaims() {
        #expect(
            AudioRoute.fullDuplex.configuration
                == AudioSessionConfiguration(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
        )
        #expect(
            AudioRoute.playback.configuration
                == AudioSessionConfiguration(
                    category: .playback,
                    mode: .spokenAudio,
                    options: []
                )
        )
        #expect(
            AudioRoute.capture.configuration
                == AudioSessionConfiguration(
                    category: .record,
                    mode: .measurement,
                    options: [.allowBluetoothHFP]
                )
        )
    }

    /// 配置是**集合语义**：选项顺序不携带信息，所以两条写法必须相等。
    ///
    /// 没有这条归一化，判据就只能逐字比选项数组，于是「谁先写」变成一个隐藏约束。
    @Test func optionOrderDoesNotMatter() {
        #expect(
            AudioSessionConfiguration(
                category: .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
                == AudioSessionConfiguration(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
        )
    }

    /// 三条路线的类别必须互不相同。
    ///
    /// 这是 `AudioSessionOccupancy.derive` 的**前提**：它靠类别反推认领者。
    /// 两条路线共用一个类别会让反推变成猜，而猜错的方向恰好是「以为没人占、于是去抢」。
    @Test func theRouteCategoriesAreDistinctSoOccupancyCanBeInverted() {
        let categories = AudioRoute.allCases.map(\.configuration.category)
        #expect(Set(categories).count == categories.count)

        // 反推也要真的回得来（不只是「互不相同」）。
        for route in AudioRoute.allCases {
            let snapshot = AudioSessionSnapshot(
                category: route.configuration.category.rawValue,
                mode: route.configuration.mode.rawValue,
                sampleRate: 16_000,
                otherAudioPlaying: false
            )
            #expect(AudioSessionOccupancy.derive(from: snapshot).holder == .claimed(route))
        }
    }

    /// 首选值与上行格式对齐：16 kHz 单声道 PCM16，20 ms 的 IO buffer。
    @Test func thePreferredIOValuesMatchTheUplinkFormat() {
        #expect(AudioRoute.preferredSampleRate == 16_000)
        #expect(AudioRoute.preferredIOBufferDuration == 0.02)
    }

    // MARK: - 占用推导

    @Test func eachClaimedCategoryReportsItsRoute() {
        #expect(holder(category: .playAndRecord) == .claimed(.fullDuplex))
        #expect(holder(category: .playback) == .claimed(.playback))
        #expect(holder(category: .record) == .claimed(.capture))
    }

    /// 空的类别 rawValue 是「**没有会话**」，不是「一个我们不认识的类别」。
    ///
    /// 分清这两件事是因为它们读数不同：非 iOS 的端口（那里没有 `AVAudioSession`）
    /// 返回空字符串，而 `.noOne` 正是那个平台上的事实。合成 `.notOurClaim("")` 会让
    /// 遥测与测试替身都读成「有个奇怪的占用者」。
    @Test func anEmptyCategoryMeansThereIsNoSessionRatherThanAnUnknownOne() {
        let occupancy = AudioSessionOccupancy.derive(
            from: AudioSessionSnapshot(category: "", mode: "", sampleRate: 0, otherAudioPlaying: false)
        )
        #expect(occupancy.holder == .noOne)
        #expect(occupancy.reportsASampleRate == false)
    }

    /// 我们没设过的类别要**如实报出来**，但不能被当成「别人占着」。
    ///
    /// 这是这一层最容易写错的地方，而第一版就是错的（判据当场抓出来）：把认不出的类别
    /// 归成「别人占着、于是让路」，会让**每日一读在 App 启动后永远拿不到 `.playback`**
    /// —— 因为一进来看到的就是系统默认类别，锁屏播放直接坏掉。
    ///
    /// 事实是：类别是**每进程**的属性，别的 App 改不了我们的会话（它们只体现为
    /// `otherAudioPlaying`），而本仓只有一条路径会设类别、还有守卫盯着不许绕过
    /// ⇒ 认不出的值只可能来自「我们没设过」。
    @Test func aCategoryWeNeverSetIsReportedAsNotOurClaim() {
        let occupancy = AudioSessionOccupancy.derive(
            from: AudioSessionSnapshot(
                category: "AVAudioSessionCategoryAmbient",
                mode: "AVAudioSessionModeDefault",
                sampleRate: 44_100,
                otherAudioPlaying: true
            )
        )
        #expect(occupancy.holder == .notOurClaim(category: "AVAudioSessionCategoryAmbient"))
        #expect(occupancy.holder.route == nil)
        #expect(occupancy.otherAudioPlaying)
        #expect(occupancy.holder.usesTheInputRoute == false, "我们没设过的类别没有输入路线可拆")
    }

    /// 让路的理由只有一条：**换掉它会不会拆掉输入路线**。
    ///
    /// 这条把判据写成一张表，这样「将来加一条路线」时，忘记录入这张表的后果是判据红，
    /// 而不是静默多出一条抢夺路径。
    @Test func onlyRoutesWithAnInputRouteBlockPlayback() {
        #expect(AudioSessionHolder.claimed(.capture).usesTheInputRoute)
        #expect(AudioSessionHolder.claimed(.fullDuplex).usesTheInputRoute)
        #expect(AudioSessionHolder.claimed(.playback).usesTheInputRoute == false)
        #expect(AudioSessionHolder.noOne.usesTheInputRoute == false)
        #expect(AudioSessionHolder.notOurClaim(category: "whatever").usesTheInputRoute == false)

        let inputRoutes = AudioRoute.allCases.filter {
            AudioSessionHolder.claimed($0).usesTheInputRoute
        }
        #expect(inputRoutes == [.capture, .fullDuplex])
    }

    /// 类别与模式在 deactivate 之后**存活**，所以「像一个采集会话、采样率为 0」
    /// 是一个真实状态，不是矛盾 —— 占用者仍然是说的房间，只是暂时不活跃。
    ///
    /// 这条很重要：如果把「不活跃」读成「没人占」，下一次认领就会去抢一个
    /// 随时会被房间重新激活的会话。
    @Test func aDeactivatedSessionStillReportsItsClaimer() {
        let occupancy = AudioSessionOccupancy.derive(
            from: AudioSessionSnapshot(
                category: AudioSessionCategory.playAndRecord.rawValue,
                mode: AudioSessionMode.voiceChat.rawValue,
                sampleRate: 0,
                otherAudioPlaying: false
            )
        )
        #expect(occupancy.holder == .claimed(.fullDuplex))
        #expect(occupancy.reportsASampleRate == false)
    }

    /// 遥测那一行的字段表**只有一份**（这里钉住它）。
    ///
    /// 设备上一次「一行代码都不执行的失败」只能靠这类痕迹归因，本仓为此付过两次
    /// 「两侧单测全绿而真机静音」的代价。少一个字段等于少一条线索，而少字段是静默的。
    @Test func theTelemetrySummaryCarriesEveryField() {
        let summary = AudioSessionSnapshot(
            category: "AVAudioSessionCategoryPlayAndRecord",
            mode: "AVAudioSessionModeVoiceChat",
            sampleRate: 16_000,
            otherAudioPlaying: true,
            secondaryAudioShouldBeSilenced: false
        ).telemetrySummary

        for field in ["category=", "mode=", "sampleRate=", "otherAudio=", "duckHint="] {
            #expect(summary.contains(field), "遥测行少了 \(field)：\(summary)")
        }
        // 采样率要取整 —— 真机日志里 `16000.0` 与 `16000` 的噪声没有价值。
        #expect(summary.contains("sampleRate=16000"), "\(summary)")
    }

    // MARK: - 认领策略

    /// **2026-09-24 事故本身，作为一条判据。**
    ///
    /// 房间占着的时候，每日一读必须**不动类别**。这不是「偏好」：`AVPlayer`
    /// 在 `.playAndRecord` 下照样能放 —— 它不需要赢这场争夺，只需要不替对方输掉。
    @Test func dailyReadKeepsTheCategoryWhileTheSpeakingRoomHoldsIt() {
        let decision = AudioSessionPolicy.claim(
            for: .playback,
            given: occupancy(holder: .claimed(.fullDuplex))
        )
        #expect(decision == .keepCategory(heldBy: .claimed(.fullDuplex)))
    }

    /// **App 刚启动**时每日一读必须能拿到 `.playback`。
    ///
    /// 这条是一条回归判据，写下它的时候它**是红的**：第一版策略让位给一切
    /// 「认不出的类别」，而真机上一进 App 会话的类别就是系统默认值
    /// （不是我们那三个中的任何一个）⇒ 每日一读永远拿不走类别，
    /// 1️⃣ 锁屏继续播 这个功能直接坏掉 —— 比它要防的那个事故更常发生。
    ///
    /// 注意这条**不依赖「默认类别到底是什么」**：那属于系统实现细节，
    /// 而决策只问「换掉它会不会拆掉输入路线」。所以这里用一个我们永远不设的值代表它。
    @Test func dailyReadTakesPlaybackOnAFreshLaunch() {
        for category in ["AVAudioSessionCategorySoloAmbient", "AVAudioSessionCategoryAmbient", ""] {
            let decision = AudioSessionPolicy.claim(
                for: .playback,
                given: occupancy(holder: .notOurClaim(category: category))
            )
            #expect(
                decision == .reconfigure(.playback),
                "类别 \(category) 时每日一读拿不到播放路线 —— 锁屏播放会坏"
            )
        }
    }

    /// 房间占着（`.playAndRecord`）时让路：类别不动、只激活 —— `AVPlayer` 在它下面照样能放。
    @Test func dailyReadDoesNotStealFromTheSpeakingRoom() {
        #expect(
            AudioSessionPolicy.claim(for: .playback, given: occupancy(holder: .claimed(.fullDuplex)))
                == .keepCategory(heldBy: .claimed(.fullDuplex))
        )
    }

    /// **让路之前先问「让了之后还听不听得到」。**
    ///
    /// 旧判据把 `.claimed(.capture)` 也归进「让路」，理由是「那会拆掉 input route」——
    /// 理由对，结论错：`.record` 是 input-only，在它下面播什么都听不见，所以「让路」
    /// 等于**静默**。而静音是本项目唯一不可接受的失败。
    ///
    /// `.capture` 今天没有生产调用方（票里写明了），但这条判据是它唯一的保护：
    /// 接上发音评测那天，「不能偷偷播」这件事已经被写下来了。
    @Test func dailyReadRefusesRatherThanPlaySilentlyUnderAnInputOnlyHolder() {
        #expect(
            AudioSessionPolicy.claim(for: .playback, given: occupancy(holder: .claimed(.capture)))
                == .refuseBecauseTheHolderHasNoOutputRoute(heldBy: .claimed(.capture)),
            "input-only 的占用者被当成「让路」处理 —— 那就成了播了但没声"
        )
    }

    /// 「有没有输出路线」是一张**推导表**，不是一个名单：能出声的只有那两个播放得了的类别。
    @Test func onlyCategoriesThatCanPlayHaveAnOutputRoute() {
        #expect(AudioSessionHolder.claimed(.capture).hasOutputRoute == false)
        for holder: AudioSessionHolder in [
            .claimed(.fullDuplex), .claimed(.playback), .noOne,
            .notOurClaim(category: "AVAudioSessionCategorySoloAmbient"),
        ] {
            #expect(holder.hasOutputRoute, "\(holder.label) 被当成了不能出声")
        }

        let withoutOutput = AudioRoute.allCases.filter {
            AudioSessionHolder.claimed($0).hasOutputRoute == false
        }
        #expect(withoutOutput == [.capture], "能出声的路线集合变了：\(withoutOutput)")
    }

    /// **采样率非 0 ≠ 会话活着**（真机反证，钉住这份读数本身）。
    ///
    /// 2026-09-28 那次真机运行的 `[Scenario] session@after-bootstrap` 行：
    /// 我们**从没认领过**的会话（`notOurClaim(SoloAmbient)`）报
    /// `sampleRate=48000 otherAudio=true`。所以这个布尔只能叫「系统报了个硬件采样率」，
    /// 不能叫「会话活着」—— 判据把那个读数**原样**放在这里，免得下一个人又拿它去断言
    /// 「会话被激活了」（F6 的验收判据 1 就是这么写的）。
    @Test func aNonZeroSampleRateIsNotEvidenceThatTheSessionIsActive() {
        let asMeasuredOnDevice = AudioSessionOccupancy.derive(
            from: AudioSessionSnapshot(
                category: "AVAudioSessionCategorySoloAmbient",
                mode: "AVAudioSessionModeDefault",
                sampleRate: 48_000,
                otherAudioPlaying: true
            )
        )

        #expect(asMeasuredOnDevice.holder == .notOurClaim(category: "AVAudioSessionCategorySoloAmbient"))
        #expect(asMeasuredOnDevice.reportsASampleRate, "这一行就是反证：没人认领、采样率却是 48000")
    }

    @Test func dailyReadTakesTheCategoryWhenItIsFreeOrAlreadyOurs() {
        #expect(
            AudioSessionPolicy.claim(for: .playback, given: occupancy(holder: .noOne))
                == .reconfigure(.playback)
        )
        #expect(
            AudioSessionPolicy.claim(for: .playback, given: occupancy(holder: .claimed(.playback)))
                == .reconfigure(.playback)
        )
    }

    /// 要 input route 的路线总是重配 —— 哪怕占用者是别人（它不工作的话，让步等于什么都不做）。
    @Test func routesThatNeedTheInputRouteAlwaysReconfigure() {
        for holder: AudioSessionHolder in [
            .noOne,
            .claimed(.playback),
            .claimed(.fullDuplex),
            .notOurClaim(category: "AVAudioSessionCategoryAmbient"),
        ] {
            #expect(
                AudioSessionPolicy.claim(for: .fullDuplex, given: occupancy(holder: holder))
                    == .reconfigure(.fullDuplex),
                "占用者 \(holder.label) 时，说的房间仍然必须重配"
            )
            #expect(
                AudioSessionPolicy.claim(for: .capture, given: occupancy(holder: holder))
                    == .reconfigure(.capture),
                "占用者 \(holder.label) 时，采集仍然必须重配"
            )
        }
    }

    // MARK: - 归还策略

    /// 归还方向的那一半：**最后一个在册的租约**离开时才 deactivate。
    ///
    /// 这一半在 2026-09-29 之前没人守，而且是个**活缺陷**：每日一读的 `teardown()`
    /// 无条件 `setActive(false)` ——「朗读放完」会把正在跑的说的房间一起关掉，
    /// 与 2026-09-24 同类，只是方向相反。
    @Test func releaseDeactivatesOnlyWhenTheRequesterHoldsIt() {
        #expect(
            AudioSessionPolicy.release(
                from: .playback,
                given: occupancy(holder: .claimed(.playback)),
                holdsALease: true,
                remainingLeases: []
            ) == .deactivate
        )
        #expect(
            AudioSessionPolicy.release(
                from: .playback,
                given: occupancy(holder: .noOne),
                holdsALease: true,
                remainingLeases: []
            ) == .deactivate
        )
    }

    /// **房间还在册时，每日一读归还它借来的会话，不许关掉它。**
    ///
    /// 上一条的判据从类别推「谁在占」，而这一条只有租约名册答得出来：房间占着 `.playAndRecord`，
    /// 每日一读借它播（`keepCategory`，只激活不切类别 ⇒ **类别上一点痕迹都没有**）。
    @Test func releasingDailyReadDoesNotDeactivateWhileTheSpeakingRoomHoldsIt() {
        #expect(
            AudioSessionPolicy.release(
                from: .playback,
                given: occupancy(holder: .claimed(.fullDuplex)),
                holdsALease: true,
                remainingLeases: [.fullDuplex]
            ) == .keepLeased(by: [.fullDuplex])
        )
    }

    /// 反过来：**房间收尾时，正在借的每日一读不能被弄哑。**
    ///
    /// 这是同一条事故的另一半，而它在租约模型之前**根本表达不出来** —— 那时从类别看
    /// 房间自己就是占用者，于是 `deactivate` 看起来完全正确。
    @Test func releasingTheRoomDoesNotDeactivateWhileTheDailyReadBorrowsIt() {
        #expect(
            AudioSessionPolicy.release(
                from: .fullDuplex,
                given: occupancy(holder: .claimed(.fullDuplex)),
                holdsALease: true,
                remainingLeases: [.playback]
            ) == .keepLeased(by: [.playback])
        )
    }

    /// 不持有租约的归还是一句空话：不许关掉别人的会话。
    @Test func releaseWithoutALeaseNeverDeactivates() {
        for holder: AudioSessionHolder in [
            .claimed(.fullDuplex), .claimed(.playback), .notOurClaim(category: "AVAudioSessionCategorySoloAmbient"),
        ] {
            #expect(
                AudioSessionPolicy.release(
                    from: .playback,
                    given: occupancy(holder: holder),
                    holdsALease: false,
                    remainingLeases: []
                ) == .keep(heldBy: holder)
            )
        }
    }

    /// 名册里还有**别的**路线就不许关 —— 哪怕类别看起来是我们自己占着的。
    @Test func releaseKeepsDeactivatingBlockedWhileAnyOtherLeaseIsOnTheBooks() {
        for other: AudioRoute in AudioRoute.allCases where other != .fullDuplex {
            #expect(
                AudioSessionPolicy.release(
                    from: .fullDuplex,
                    given: occupancy(holder: .claimed(.fullDuplex)),
                    holdsALease: true,
                    remainingLeases: [other]
                ) == .keepLeased(by: [other])
            )
        }
    }

    /// 归还方向仍然保守：类别不是我们设的就不碰。
    ///
    /// 与认领方向的不对称是**有意的**：认领时不接管会让功能坏掉（见上一条），
    /// 而归还时不动只是「少关一次会话」，代价为零 —— 所以这一侧取保守值。
    @Test func releaseKeepsACategoryWeNeverSet() {
        #expect(
            AudioSessionPolicy.release(
                from: .playback,
                given: occupancy(holder: .notOurClaim(category: "AVAudioSessionCategoryAmbient")),
                holdsALease: true,
                remainingLeases: []
            )
                == .keep(heldBy: .notOurClaim(category: "AVAudioSessionCategoryAmbient"))
        )
    }

    // MARK: - 帮手

    private func holder(category: AudioSessionCategory) -> AudioSessionHolder {
        AudioSessionOccupancy.derive(
            from: AudioSessionSnapshot(
                category: category.rawValue,
                mode: "",
                sampleRate: 16_000,
                otherAudioPlaying: false
            )
        ).holder
    }

    private func occupancy(holder: AudioSessionHolder) -> AudioSessionOccupancy {
        AudioSessionOccupancy(holder: holder, reportsASampleRate: true, otherAudioPlaying: false)
    }
}
