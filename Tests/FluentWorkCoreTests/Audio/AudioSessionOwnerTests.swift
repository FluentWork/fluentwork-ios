import Foundation
import Testing
import os

@testable import FluentWorkCore

/// 主人**实际做了什么** —— 判据看的是端口的调用记录，不是返回值。
///
/// 这是这一票的核心测法：策略是纯函数（`AudioSessionPolicyTests` 覆盖），
/// 而「有没有真的把类别切走」只有在端口那一层才看得见。所以这里注入一个脚本化的端口，
/// 并把它的快照做成**会跟随 `apply` 变化**的 —— 那是系统的行为，不是我们的愿望。
@Suite struct AudioSessionOwnerTests {

    /// **2026-09-24 事故的回归判据。**
    ///
    /// 房间占着（类别 = `playAndRecord`）时，每日一读认领播放**必须一次都不调 `setCategory`**，
    /// 只激活。切走类别会拆掉 input route，正在跑的引擎会自己停，而它一行我们的代码都不执行。
    ///
    /// 房间那一次认领是**真的走了一遍**（不是把端口快照摆成 `playAndRecord`）：租约模型之后
    /// 「类别上像那么回事」和「房间里真的有个会话在跑」是两件事，判据要按后者的形状写。
    @Test func dailyReadNeverReconfiguresWhileTheSpeakingRoomHoldsTheSession() throws {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed)
        let owner = SharedAudioSessionOwner(port: port)
        _ = try owner.claim(.fullDuplex)
        let appliedAfterTheRoom = port.calls.applied

        let decision = try owner.claim(.playback)

        #expect(decision == .keepCategory(heldBy: .claimed(.fullDuplex)))
        #expect(
            port.calls.applied == appliedAfterTheRoom,
            "类别被切走了：\(port.calls.applied) —— 这正是 2026-09-24 那次静默事故"
        )
        #expect(port.calls.activeChanges == [true, true])
        // 类别没被动过，所以它仍然是采集会话。
        #expect(owner.occupancy().holder == .claimed(.fullDuplex))
    }

    @Test func dailyReadTakesTheCategoryWhenNobodyHoldsIt() throws {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed)
        let owner = SharedAudioSessionOwner(port: port)

        let decision = try owner.claim(.playback)

        #expect(decision == .reconfigure(.playback))
        #expect(port.calls.applied == [AudioRoute.playback.configuration])
        #expect(port.calls.activeChanges == [true])
        #expect(owner.occupancy().holder == .claimed(.playback))
    }

    /// 占用是**从端口读的**，不是主人记着的。
    ///
    /// 这条用一个别人抢走会话的场景来证明：主人自己从没认领过 `.fullDuplex`，
    /// 但端口那边的类别变了 —— 于是下一次认领必须让路。
    /// 一个缓存下来的标志位在这里会**报错方向**（它会说「没人占」然后去抢）。
    @Test func occupancyIsReadFromTheSessionNotRememberedByTheOwner() throws {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed)
        let owner = SharedAudioSessionOwner(port: port)

        #expect(owner.occupancy().holder == .noOne)

        // 别的组件（或同一个 App 的另一条路径）把会话拿走了。
        port.forceSnapshot(.active(category: .playAndRecord, mode: .voiceChat))

        #expect(owner.occupancy().holder == .claimed(.fullDuplex))
        #expect(
            try owner.claim(.playback) == .keepCategory(heldBy: .claimed(.fullDuplex)),
            "主人必须读当下的会话，而不是它自己上一次认领留下的印象"
        )
    }

    /// **同一类事故的归还方向**（这是一条在 2026-09-29 之前没人守的活缺陷）。
    ///
    /// 每日一读放完就归还。房间还在跑（在册）的时候归还**不能** deactivate ——
    /// 那会把正在进行的练习会话关掉，同样是一行代码都不执行地停。
    @Test func releasingDailyReadDoesNotDeactivateWhileTheSpeakingRoomRuns() throws {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed)
        let owner = SharedAudioSessionOwner(port: port)
        _ = try owner.claim(.fullDuplex)   // 房间在跑，并且它在册
        _ = try owner.claim(.playback)     // 每日一读借了它

        let decision = try owner.release(from: .playback)

        #expect(decision == .keepLeased(by: [.fullDuplex]))
        #expect(
            port.calls.activeChanges == [true, true],
            "归还时把会话关了：\(port.calls.activeChanges) —— 正在跑的说的房间会静默停掉"
        )
    }

    /// 租约是**计数**的：认领两次就要归还两次，第一次归还什么都不该动。
    @Test func claimingTwiceRequiresReleasingTwice() throws {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed)
        let owner = SharedAudioSessionOwner(port: port)
        _ = try owner.claim(.playback)
        _ = try owner.claim(.playback)

        #expect(try owner.release(from: .playback) == .keepLeased(by: [.playback]))
        #expect(
            port.calls.activeChanges == [true, true],
            "还有一次租约在册就把会话关了：\(port.calls.activeChanges)"
        )

        #expect(try owner.release(from: .playback) == .deactivate)
        #expect(port.calls.activeChanges == [true, true, false])
    }

    /// 不持有租约的人归还：**不许**关掉别人的会话，也不许改坏名册。
    ///
    /// 这条是「认领/归还必须配对」的守卫：一个从没认领过的组件（例如说房间失败后
    /// 才走到归还的路径）不能把还在跑的房间关掉。
    @Test func releasingWithoutALeaseLeavesTheSessionAndTheRegisterAlone() throws {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed)
        let owner = SharedAudioSessionOwner(port: port)
        _ = try owner.claim(.fullDuplex)   // 房间里有人在跑

        let decision = try owner.release(from: .playback)   // 一个没借过的人来归还

        #expect(decision == .keep(heldBy: .claimed(.fullDuplex)))
        #expect(
            port.calls.activeChanges == [true],
            "一个没持有租约的组件关掉了别人的会话：\(port.calls.activeChanges)"
        )
        // 名册没被弄坏：房间那次认领还在，所以它一次归还是真的能关。
        #expect(try owner.release(from: .fullDuplex) == .deactivate)
        #expect(port.calls.activeChanges == [true, false])
    }

    @Test func releasingDailyReadDeactivatesOnlyWhenItHoldsTheSession() throws {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed)
        let owner = SharedAudioSessionOwner(port: port)
        _ = try owner.claim(.playback)

        let decision = try owner.release(from: .playback)

        #expect(decision == .deactivate)
        #expect(port.calls.activeChanges == [true, false])
    }

    /// **房间收尾归还时，不许把还在播的每日一读弄哑。**
    ///
    /// 房间占着会话时，每日一读是「借」的：它 `claim(.playback)` 只激活、不切类别
    /// （那是对的，切了会拆掉 input route），但它**在会话上没留下任何痕迹** —— 类别仍是
    /// `.playAndRecord`，所以从会话派生出来的占用者看起来还是房间。
    /// 于是今天的 `release(from: .fullDuplex)` 会判定「是我自己占着」→ `setActive(false)`
    /// → 正在播的朗读当场静音。这正是本票另一个方向上的同类事故。
    ///
    /// 这条判据是 R2 的证据：**「谁占了类别」能从进程级类别派生出来，但「谁在借」不能** ——
    /// `AVAudioSession` 里没有这个信息。要让两条归还路径都安全，主人必须记一份借用者名册。
    @Test func releasingTheRoomDoesNotSilenceTheDailyReadThatBorrowedIt() throws {
        let port = ScriptedAudioSessionPort(
            snapshot: .active(category: .playAndRecord, mode: .voiceChat)
        )
        let owner = SharedAudioSessionOwner(port: port)
        _ = try owner.claim(.playback)

        let decision = try owner.release(from: .fullDuplex)

        #expect(decision == .keep(heldBy: .claimed(.fullDuplex)))
        #expect(
            port.calls.activeChanges == [true],
            "归还时把会话关了 —— 正在播的每日一读被静音：\(port.calls.activeChanges)"
        )
    }

    /// 激活失败要报成会话冲突，而且**把底层错误带出来** ——
    /// 中间件按这个 case 生成用户可见文案（「请关掉正在用音频的 App」）。
    @Test func activationFailureIsReportedAsASessionConflict() {
        let port = ScriptedAudioSessionPort(snapshot: .unclaimed, activationFailure: "boom")
        let owner = SharedAudioSessionOwner(port: port)

        do {
            _ = try owner.claim(.playback)
            Issue.record("应当抛 audioSessionConflict")
        } catch let error as AudioEngineError {
            guard case .audioSessionConflict(let message) = error else {
                Issue.record("抛错了 case：\(error)")
                return
            }
            #expect(message.contains("close other apps using audio"))
            #expect(message.contains("boom"), "底层错误被吞了：\(message)")
        } catch {
            Issue.record("抛了非 AudioEngineError：\(error)")
        }
    }
}

// MARK: - 脚本化端口

/// 记录调用、并让快照跟随 `apply` 变化的端口替身。
///
/// 「跟随变化」是关键：真实系统在 `setCategory` 之后就会报告新类别，而主人下一次
/// 认领读的正是那个值。不会变化的替身会让「占用是读出来的」这条性质测不出来。
final class ScriptedAudioSessionPort: AudioSessionPorting, @unchecked Sendable {
    struct Calls: Equatable {
        var applied: [AudioSessionConfiguration] = []
        var activeChanges: [Bool] = []
    }

    private struct State {
        var snapshot: AudioSessionSnapshot
        var calls = Calls()
    }

    private let storage: OSAllocatedUnfairLock<State>
    private let activationFailure: String?

    init(snapshot: AudioSessionSnapshot, activationFailure: String? = nil) {
        self.storage = OSAllocatedUnfairLock(initialState: State(snapshot: snapshot))
        self.activationFailure = activationFailure
    }

    var calls: Calls {
        storage.withLock { $0.calls }
    }

    /// 模拟「别人改了会话」—— 绕过本端口，直接改系统状态。
    func forceSnapshot(_ snapshot: AudioSessionSnapshot) {
        storage.withLock { $0.snapshot = snapshot }
    }

    func snapshot() -> AudioSessionSnapshot {
        storage.withLock { $0.snapshot }
    }

    func apply(_ configuration: AudioSessionConfiguration) throws {
        storage.withLock {
            $0.calls.applied.append(configuration)
            $0.snapshot.category = configuration.category.rawValue
            $0.snapshot.mode = configuration.mode.rawValue
        }
    }

    func setActive(_ active: Bool) throws {
        if active, let activationFailure {
            storage.withLock { $0.calls.activeChanges.append(active) }
            throw ScriptedAudioSessionFailure(message: activationFailure)
        }
        storage.withLock {
            $0.calls.activeChanges.append(active)
            // 被 deactivate 的会话报告零采样率（活动性的代理）。
            $0.snapshot.sampleRate = active ? 16_000 : 0
        }
    }
}

private struct ScriptedAudioSessionFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 快照构造

extension AudioSessionSnapshot {
    /// 「没人认领」——类别是空的（macOS 端口在非 iOS 上就是这个形状，本 App 启动时也是）。
    fileprivate static var unclaimed: AudioSessionSnapshot {
        AudioSessionSnapshot(category: "", mode: "", sampleRate: 0, otherAudioPlaying: false)
    }

    /// 某个类别正被用着。
    fileprivate static func active(
        category: AudioSessionCategory,
        mode: AudioSessionMode
    ) -> AudioSessionSnapshot {
        AudioSessionSnapshot(
            category: category.rawValue,
            mode: mode.rawValue,
            sampleRate: 16_000,
            otherAudioPlaying: false
        )
    }
}
