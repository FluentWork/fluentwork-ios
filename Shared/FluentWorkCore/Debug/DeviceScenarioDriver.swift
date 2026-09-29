#if DEBUG
import Foundation
import TGReduxKit

/// 真机场景驱动（**仅 DEBUG**，由 `FW_SCENARIO` 开启）—— F6 的验收工具。
///
/// ## 为什么是「派动作」而不是「模拟点击」
///
/// 这个界面是 Redux 的：**store 是唯一真源**，而真机上要证的两件事全在
/// Action → Middleware → 引擎 这条链上，不在视图里：
///
/// 1. 会话类别**真的落到系统**了吗（`claim(.fullDuplex)` 之后 `AVAudioSession` 怎么说）；
/// 2. 每日一读开始播时，**会不会拆掉正在跑的说的房间**（2026-09-24 事故）。
///
/// 两件事都只需要「照视图派同样的 action，然后读 state 与音频会话」。这比模拟点击
/// 更稳（不依赖布局/时序/无障碍标识），也直接落在本仓已有的测试形状上
/// （`AppStoreFactory.make` + `store.dispatch` + 等状态）。
///
/// ## 唯一的纪律：**照抄视图，不自创流程**
///
/// 每一步都标了它抄自 `App/FluentWorkHost/HostRootView.swift` 的哪一行。
/// 这个文件不该有自己的「测试专用流程」—— 那样它验的就不是真机上的那条路了。
///
/// ## 它不做什么
///
/// 不加任何生产行为、不碰视图、不改变默认路径。没设 `FW_SCENARIO` 时它一个字节都不执行。
///
/// ## 怎么用
///
/// ```
/// FW_SCENARIO=room+daily    # 起会话 + 同时播每日一读（验上面两件事）
/// FW_SCENARIO=room          # 只起会话
/// FW_MOCK_MIC=1 FW_MOCK_MIC_AUTO_MS=4000   # 麦克风替身（无人值守）
/// ```
/// `Scripts/smoke-device.sh` 会带上这几个变量，并读 `[Scenario]` 行。
public enum DeviceScenarioDriver {

    public enum Kind: String {
        /// 起一个练习会话。
        case room
        /// 上面 + 同时播每日一读 —— 「朗读不拆掉正在跑的房间」。
        case roomAndDaily = "room+daily"
    }

    public static var configured: Kind? {
        guard let raw = ProcessInfo.processInfo.environment["FW_SCENARIO"] else { return nil }
        return Kind(rawValue: raw)
    }

    public static func runIfConfigured(store: AppStore) async {
        guard let kind = configured else { return }
        await run(kind, store: store)
    }

    // MARK: - 场景

    @MainActor
    static func run(_ kind: Kind, store: AppStore) async {
        log("start scenario=\(kind.rawValue)")
        var failures: [String] = []

        // ① 启动 → 等 bootstrap。
        //    抄自 `HostRootView.swift:66`（`store.dispatch(.lifecycle(.appLaunched))`）。
        store.dispatch(.lifecycle(.appLaunched))
        let booted = await wait(seconds: 25) { store.state.bootstrapStatus == .ready }
        log("bootstrap ready=\(booted) status=\(store.state.bootstrapStatus.rawValue)")
        logSession("after-bootstrap")
        if !booted {
            failures.append("bootstrap 未在 25 秒内 ready（status=\(store.state.bootstrapStatus.rawValue)）")
        }

        // ② 进房间。抄自 `HostRootView.swift:196` 的 `.enterRoom(continueFrom:seeding:)`。
        store.dispatch(.speakingRoom(.enterRoom(continueFrom: nil, seeding: [])))
        _ = await wait(seconds: 10) { store.state.speakingRoom.phase != .idle }
        log("room entered phase=\(store.state.speakingRoom.phase.rawValue)")

        // ③ 开始说话。抄自 `HostRootView.swift:89` 的 `.manualSpeechBegin`
        //    （真机上是「开始说话」那个按钮；这里由麦克风替身把那一轮说完）。
        store.dispatch(.speakingRoom(.manualSpeechBegin))
        let captureStarted = await wait(seconds: 30) {
            store.state.speakingRoom.phase == .recording
                || store.state.speakingRoom.phase == .processing
        }
        log("capture started=\(captureStarted) phase=\(store.state.speakingRoom.phase.rawValue)")
        let afterCapture = logSession("after-capture-start")

        // **验收 1**：类别必须真的落到系统。单测只能证明「我们决定要配成什么」，
        // 证不了 `setCategory` 真的被系统接受了 —— 这一行才是那个证据。
        if captureStarted {
            if afterCapture.category != AudioSessionCategory.playAndRecord.rawValue {
                failures.append(
                    "采集开始后类别是 \(afterCapture.category)，期望 \(AudioSessionCategory.playAndRecord.rawValue)"
                )
            }
            if afterCapture.mode != AudioSessionMode.voiceChat.rawValue {
                failures.append("采集开始后模式是 \(afterCapture.mode)，期望 \(AudioSessionMode.voiceChat.rawValue)")
            }
            if !afterCapture.looksActive {
                failures.append("采集开始后采样率是 0 —— 会话没被激活")
            }
        } else {
            failures.append("30 秒内没有进入采集（phase=\(store.state.speakingRoom.phase.rawValue)）")
        }

        // ④ 房间**还在跑**的时候播每日一读。
        //    抄自 `HostRootView.swift:235` 的 `.dailyRead(.loadTriggered)`。
        if kind == .roomAndDaily {
            store.dispatch(.dailyRead(.loadTriggered))
            let playing = await wait(seconds: 35) { store.state.dailyRead.audioPhase == .playing }
            log(
                "dailyRead audio playing=\(playing)"
                    + " audioPhase=\(store.state.dailyRead.audioPhase.rawValue)"
                    + " screenPhase=\(store.state.dailyRead.phase.rawValue)"
            )
            let afterDailyRead = logSession("after-daily-read-play")

            // **验收 2（2026-09-24 事故的回归）**：朗读认领播放时，房间占着的
            // `.playAndRecord` 必须**原样不动** —— 切走它会拆掉 input route，
            // 让正在跑的引擎一行代码都不执行地停。
            if afterDailyRead.category != AudioSessionCategory.playAndRecord.rawValue {
                failures.append(
                    "朗读开播后类别变成了 \(afterDailyRead.category) —— 房间的 input route 被拆掉了"
                )
            }
            // 房间本身也必须还活着：引擎停了 phase 会掉出 recording/processing。
            let roomPhase = store.state.speakingRoom.phase
            if roomPhase == .failed || roomPhase == .idle {
                failures.append("朗读开播后房间 phase=\(roomPhase.rawValue)，它被弄停了")
            }
            if !playing {
                failures.append("35 秒内每日一读没有开始播（audioPhase=\(store.state.dailyRead.audioPhase.rawValue)）")
            }
        }

        // ⑤ 收尾。抄自 `HostRootView.swift:97/99`。
        store.dispatch(.speakingRoom(.manualSpeechEnd))
        _ = await wait(seconds: 10) { store.state.speakingRoom.phase != .recording }
        log("final room phase=\(store.state.speakingRoom.phase.rawValue)")
        logSession("after-end")

        if failures.isEmpty {
            log("verdict=PASS")
        } else {
            log("verdict=FAIL reasons=\(failures.joined(separator: " | "))")
        }
        log("done")
    }

    // MARK: - 观测

    /// 读一次真实会话，打一行，并把快照交回给判据。
    ///
    /// 用 `SharedAudioSessionPort` 直接读 —— 与主人读的是**同一个**端口，
    /// 所以这一行报的就是主人做决定时看的那份事实。
    @discardableResult
    private static func logSession(_ label: String) -> AudioSessionSnapshot {
        let snapshot = SharedAudioSessionPort().snapshot()
        let occupancy = AudioSessionOccupancy.derive(from: snapshot)
        log(
            "session@\(label) holder=\(occupancy.holder.label) live=\(occupancy.isLive)"
                + " \(snapshot.telemetrySummary)"
        )
        return snapshot
    }

    private static func log(_ message: String) {
        print("[Scenario] \(message)")
    }

    /// 轮询等到条件成立。真机上每件事都是异步的（网络、引擎、会话），
    /// 所以判据必须**等**而不是 sleep 一个拍脑袋的时长。
    @MainActor
    private static func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
#endif
