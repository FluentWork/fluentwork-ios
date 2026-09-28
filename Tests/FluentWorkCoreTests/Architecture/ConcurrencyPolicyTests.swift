import Foundation
import Testing

/// 并发隔离口径的守卫（F5）。
///
/// 规则在 `AGENTS.md` 的 `## Concurrency Isolation`：隔离策略是一张**封闭的表**，
/// 按「这份状态需要怎么被访问」来选，不按偏好选。这条判据只负责把其中
/// **机器可判**的两半变成真的：
///
/// 1. `NSLock` / `NSRecursiveLock` / `DispatchSemaphore` 在生产代码里零容忍
///    （`OSAllocatedUnfairLock` 是替代品，且已在实际使用）；
/// 2. 用到 `DispatchQueue` 的生产文件必须在下面登记，并写明它为什么在那儿
///    （唯一合法的用途是把队列交给系统 API；当锁用是待迁移的历史写法）。
///
/// 不成机器的那一半写在 AGENTS.md 里，不假装这里覆盖了它：「`private actor`
/// 当状态盒」没法从文本上判定，现有 3 处已逐个点名。
@Suite struct ConcurrencyPolicyTests {

    /// 允许出现 `DispatchQueue` 的**生产**文件，以及它的真实用途。
    ///
    /// 每一条都是「有理由的历史例外」：要么是系统 API 要求，要么先于口径。
    /// 新增文件想用 `DispatchQueue`，就得先在这里写下一句**为什么**——
    /// 写下理由这个动作本身，就是这条判据要拦住的东西。
    private static let allowedDispatchQueueUsers: [String: String] = [
        "Shared/FluentWorkDiagnostics/Logging.swift":
            "CapturingLogger 用串行队列护它自己的 buffer（先于口径；只在测试里做 logger）",
        "Shared/FluentWorkDiagnostics/Tracker.swift":
            "CapturingTracker 同上（先于口径；只在测试里做 tracker）",
        "Shared/FluentWorkCore/Audio/AudioInterruptionObserver.swift":
            "串行队列护 observers 数组（先于口径，做法与锁等价）",
        "Shared/FluentWorkCore/Audio/AudioSessionManaging.swift":
            "不只是护字段：AVAudioSession 的 configure/activate 调用本身必须被序列化，队列同时承担这两件事",
        "Shared/FluentWorkNetworking/NetworkClient.swift":
            "RequestCancellationBox 用串行队列护取消集合（先于口径，做法与锁等价）",
        "Shared/FluentWorkNetworking/NetworkMonitor.swift":
            "**唯一合法用途**：NWPathMonitor 初始化强制要一个 queue。同文件另有 stateQueue 是当锁用的待迁移写法",
    ]

    @Test func bannedLockPrimitivesNeverAppearInProductionCode() throws {
        var findings: [String] = []
        for banned in ["NSLock(", "NSRecursiveLock(", "DispatchSemaphore"] {
            findings += try RepositoryScan.occurrences(of: banned)
        }

        #expect(
            findings.isEmpty,
            "生产代码里出现了口径禁止的锁原语：\(findings.sorted().joined(separator: ", "))"
        )
    }

    @Test func dispatchQueueIsRegisteredWithAReason() throws {
        let offenders = try RepositoryScan.productionSources()
            .filter { source in
                Self.allowedDispatchQueueUsers[source.relativePath] == nil
                    && RepositoryScan.codeLines(of: source.text).contains { $0.text.contains("DispatchQueue") }
            }
            .map(\.relativePath)

        #expect(
            offenders.isEmpty,
            """
            这些文件用了 DispatchQueue，但没在口径的白名单里登记：
            \(offenders.joined(separator: "\n"))
            先看 AGENTS.md 的 `## Concurrency Isolation` 选对策略；确实需要系统队列的，
            在 ConcurrencyPolicyTests 的白名单里写下用途。
            """
        )
    }

    /// 白名单是双向的：文件改名、或改回注入以后不再用 `DispatchQueue` 的条目要红。
    @Test func theDispatchQueueAllowListHasNoStaleEntries() throws {
        let sources = try RepositoryScan.productionSources()
        let byPath = Dictionary(uniqueKeysWithValues: sources.map { ($0.relativePath, $0.text) })

        var missingFiles: [String] = []
        var stale: [String] = []

        for relativePath in Self.allowedDispatchQueueUsers.keys.sorted() {
            guard let text = byPath[relativePath] else {
                missingFiles.append(relativePath)
                continue
            }
            if !RepositoryScan.codeLines(of: text).contains(where: { $0.text.contains("DispatchQueue") }) {
                stale.append(relativePath)
            }
        }

        #expect(
            missingFiles.isEmpty,
            "白名单指向的文件不存在（改名或删了）：\(missingFiles.joined(separator: ", "))"
        )
        #expect(
            stale.isEmpty,
            """
            白名单里这些文件已经不再用 DispatchQueue 了，属于过期豁免，请删掉：
            \(stale.joined(separator: "\n"))
            """
        )
    }

    /// 目录失配时扫到的是空数组，而"空数组"与"全部合格"在断言那里长得一样。
    @Test func theWalkIsNotVacuous() throws {
        let scanned = try RepositoryScan.productionSources().count
        #expect(
            scanned > 100,
            "只扫到 \(scanned) 个 Swift 文件 —— 守卫在看空气（路径或目录结构变了）"
        )
    }
}
