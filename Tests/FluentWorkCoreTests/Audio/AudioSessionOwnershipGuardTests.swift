import Foundation
import Testing

/// 「不许绕过会话主人」的仓级守卫（F6 = `meta iOS-S1-10`）。
///
/// ## 要防的是什么
///
/// 2026-09-24 真机事故的**结构**原因不是「没有 owner」，是**有 owner 而有人绕过它**：
/// `LiveAudioEngine` 老实地走 `AudioSessionManaging`，而 `DailyReadAudioPlayer`
/// 直接拿 `AVAudioSession.sharedInstance()` 自己配类别。于是同一个语义有了两个实现点。
///
/// `meta 70_/27_` 的修法是**局部的**（切类别之前先看真实 category），因为 `AVPlayer`
/// 在 `.playAndRecord` 下照样能放 —— 它只是不需要赢这场争夺。但结构问题留着：
/// **下一个组件还会这么写**，而且它写的时候不会报错、不会崩溃，只会在某次真机运行里
/// 让一个正在进行的练习会话静默停住。
///
/// 所以这里把「唯一」变成机器可判的：配置会话的两条 API 只许出现在主人文件里。
@Suite struct AudioSessionOwnershipGuardTests {

    /// **全部会改变进程级会话的调用**。它们都是事故的手段，不只是当初那两条。
    ///
    /// 第一版只钉了 `setCategory` / `setActive`。其余几个同样能改会话（`setMode` 会换掉
    /// 加工方式、`setPreferred*` 会换掉硬件格式），而它们当时不在针脚里 ——
    /// 名单里的豁免文件因此可以「从第二条守卫下面绕过去」。
    private static let configuringCalls = [
        "setCategory(",
        "setActive(",
        "setMode(",
        "setPreferredSampleRate(",
        "setPreferredIOBufferDuration(",
        "overrideOutputAudioPort(",
    ]

    /// 仍然直接取共享会话对象的文件，以及**为什么它那样做不构成所有权**。
    ///
    /// 名单是双向的：条目过期（文件不再引用它、或改了名）也要红 ——
    /// 一条永远为真的豁免没有任何外部信号提示它已失效，只能自己查。
    private static let allowedToReachTheSession: [String: String] = [
        "Shared/FluentWorkCore/Audio/AudioSessionOwnership.swift":
            "**主人自己**：端口是唯一配置类别、设置首选值、激活/反激活会话的地方",
        "Shared/FluentWorkCore/Permissions/MicrophonePermission.swift":
            "只申请与查询**录制权限**（`requestRecordPermission` / `recordPermission`），"
            + "从不配置类别、也从不激活会话 —— 权限与所有权是两件事",
    ]

    /// **配置会话的调用只许出现在主人文件里。**
    ///
    /// 这条是最锋利的：它正是 2026-09-24 事故的手段（把类别切走 ⇒ 拆掉 input route）。
    /// 零容忍，只留主人自己一条豁免 —— 加豁免要动这个字典，那是一个需要解释的动作。
    @Test func onlyTheOwnerConfiguresTheSharedSession() throws {
        let offenders = try Self.offenders(for: Self.configuringCalls, allowed: [
            "Shared/FluentWorkCore/Audio/AudioSessionOwnership.swift"
        ])

        #expect(
            offenders.isEmpty,
            """
            这些文件直接配置了共享 `AVAudioSession`，而它们不是主人：
            \(offenders.joined(separator: "\n"))
            走 `AudioSessionOwning.claim(_:)` / `release(from:)` ——
            它们按**真实会话**决定能不能动类别，见 `AudioSessionPolicyTests`。
            """
        )
    }

    /// 取共享会话对象本身也收在名单里（拿它去做与所有权无关的事，需要写明理由）。
    @Test func theSharedSessionObjectIsOnlyReachedByItsOwnerAndThePermissionProbe() throws {
        let offenders = try Self.offenders(
            for: ["AVAudioSession.sharedInstance()"],
            allowed: Array(Self.allowedToReachTheSession.keys)
        )

        #expect(
            offenders.isEmpty,
            """
            这些文件直接引用了 `AVAudioSession.sharedInstance()`，但不在豁免名单里：
            \(offenders.joined(separator: "\n"))
            要么改成走主人，要么在名单里写下「为什么这不构成所有权」。
            """
        )
    }

    /// **唯一主人只许在容器里被造出来。**
    ///
    /// 上面两条守卫管的是**文件**层的唯一（谁可以碰 `AVAudioSession`）；这一条管**实例**层：
    /// `SharedAudioSessionOwner` 带着自己的锁（`gate` 是实例属性），所以两个实例之间
    /// 没有任何互斥 —— 而「说的房间与每日一读在不同线程上认领同一个进程级对象」
    /// 正是那把锁存在的理由。
    ///
    /// 两个消费者（`LiveAudioEngine` / `DailyReadAudioPlayer`）的构造器原本各有一个
    /// `= SharedAudioSessionOwner()` 默认值，那就是「凭空造第二个主人」的入口。
    /// 默认值已经删掉（强制从容器取），这条守卫防的是它悄悄回来。
    @Test func theOwnerIsOnlyConstructedByTheContainer() throws {
        let offenders = try Self.offenders(for: ["SharedAudioSessionOwner("], allowed: [
            "Shared/FluentWorkCore/Dependencies/AppDependencies.swift": "唯一注册点",
        ].keys.map { $0 })

        #expect(
            offenders.isEmpty,
            """
            这些文件自己造了一个会话主人，而它带着**自己的**锁：
            \(offenders.joined(separator: "\n"))
            请从容器取（`container.audioSessionOwner()`）—— 两个主人之间没有任何互斥。
            """
        )
    }

    /// 名单双向：条目过期（文件不存在，或不再引用它）也要红。
    @Test func theAllowListHasNoStaleEntries() throws {
        let root = RepositoryScan.repositoryRoot
        var missing: [String] = []
        var noLongerReaching: [String] = []

        for (relativePath, reason) in Self.allowedToReachTheSession {
            let url = root.appending(path: relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.append("\(relativePath)（\(reason)）")
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let live = RepositoryScan.codeLines(of: text).contains {
                $0.text.contains("AVAudioSession.sharedInstance()")
            }
            if !live { noLongerReaching.append("\(relativePath)（\(reason)）") }
        }

        #expect(missing.isEmpty, "名单指向的文件不存在（改名或删了）：\n\(missing.joined(separator: "\n"))")
        #expect(
            noLongerReaching.isEmpty,
            """
            名单里这些条目已经不再引用 `AVAudioSession.sharedInstance()` 了，属于过期豁免，请删掉：
            \(noLongerReaching.joined(separator: "\n"))
            """
        )
    }

    // MARK: - 扫描

    /// 生产代码（`Shared` + `App`）里命中任一针的文件，`路径:行号`。
    ///
    /// 只剔**整行**注释（与仓里其它守卫同一写法）：文档里提到这两条 API 是合法的，
    /// 而做行内注释剥离要处理字符串里的 `//`，截错了会变成漏报。
    private static func offenders(for needles: [String], allowed: [String]) throws -> [String] {
        let sources = try RepositoryScan.productionSources()

        #expect(
            sources.count > 100,
            "只扫到 \(sources.count) 个生产 Swift 文件 —— 守卫在看空气（目录或结构变了）"
        )

        return sources
            .filter { !allowed.contains($0.relativePath) }
            .flatMap { source in
                RepositoryScan.codeLines(of: source.text)
                    .filter { line in needles.contains { line.text.contains($0) } }
                    .map { "\(source.relativePath):\($0.number)  \($0.text.trimmingCharacters(in: .whitespaces))" }
            }
    }
}
