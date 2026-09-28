import Foundation
import Testing

/// 依赖注入的仓级守卫（F4）。
///
/// ## 要防的是什么
///
/// 每个 middleware 工厂与 `AppStoreFactory.make` 都曾写成
/// `func f(container: Container? = nil)` 后接 `let resolved = container ?? Container.shared`。
/// 这个形状的问题是**它不会失败**：
///
/// - 忘传 container 时，不会编译错、不会运行错，只是**静默**用上进程单例；
/// - 于是「测试里注册了假实现却没生效」与「生产里拿到了测试容器」这两种事故
///   **都表现为一个绿测试**；
/// - 而单例一旦被测试注册过假实现，污染是**进程级**的（见 `ContainerIsolationTests`
///   对 `Scope.Singleton` 那张共享 cache 的说明），受害的测试可能正在并发跑。
///
/// 所以判据不是「找 bug」，是**把这条静默路径从类型层删掉**：
/// container 非可选 ⇒ 组合根必须显式给，忘了就是编译错。
///
/// ## 两条判据
///
/// 1. `?? Container.shared` 在生产代码里**零容忍**。
/// 2. `Container.shared` 的出现必须落在**白名单文件**里 —— 允许的只有
///    组合根入口与 debug 注入点，两者都是「有意地碰全局」。
///
/// 注释行不算（文档里可以示范用法）；这与 `DesignTokensTests` 的仓级守卫同一写法。
///
/// ## 覆盖边界（本轮实测出来的一条）
///
/// 判据 2 是**文本匹配**，所以它咬住的是 `Container.shared` 的字面写法，
/// 咬不住 `Container.shared` 的隐式成员简写 `.shared` —— 那是编译器语法糖。
/// 判据 3 正好补上这一半：真若有人把组合根改成 `.shared`，
/// 白名单条目当场变成「过期豁免」而红。这条不是推演：写 `makeShared()` 时
/// 第一版就用了 `.shared`，判据 3 立刻咬住，于是改成写全 —— 也就说明
/// **两条判据不是重复，是互补的**。
@MainActor
@Suite struct DependencyInjectionGuardTests {

    /// 允许直接触到 `Container.shared` 的文件，以及**为什么**。
    ///
    /// 白名单是「有理由的例外」清单，不是「暂时绕过」清单：条目过期（文件不再
    /// 引用它）也要红 —— 一句没人验证的豁免就是一句谎话。
    private static let allowedSharedReferrers: [String: String] = [
        "Shared/FluentWorkCore/Architecture/AppStore.swift":
            "组合根：makeShared() 是生产的唯一入口，必须有且只有这里能拿到共享容器",
        "Shared/FluentWorkCore/Debug/DebugBootstrapConfiguration.swift":
            "debug 注入点：它在启动早期改写全局容器的 preferredSurfaceProvider，是有意的",
    ]

    @Test func noSilentSingletonFallbackInProductionCode() throws {
        let findings = try RepositoryScan.occurrences(of: "?? Container.shared")

        #expect(
            findings.isEmpty,
            """
            生产代码里还有静默回落到共享容器的路径（忘了传 container 不会报错，只会拿到单例）：
            \(findings.joined(separator: "\n"))
            把参数改成必传的 Container，并让组合根显式传。
            """
        )
    }

    @Test func theSharedContainerIsOnlyTouchedWhereItIsDeclaredAsSuch() throws {
        let offenders = try RepositoryScan.productionSources().flatMap { source in
            guard Self.allowedSharedReferrers[source.relativePath] == nil else { return [String]() }
            return RepositoryScan.codeLines(of: source.text)
                .filter { $0.text.contains("Container.shared") }
                .map { "\(source.relativePath):\($0.number)" }
        }

        #expect(
            offenders.isEmpty,
            """
            这些文件直接引用了 Container.shared，但它们不在白名单里：
            \(offenders.joined(separator: "\n"))
            要么改成注入（参数 non-optional），要么在白名单里写明它为什么是组合根。
            """
        )
    }

    /// 白名单是双向的：条目过期（文件不再引用它）也要红。
    ///
    /// 没有这条，白名单会随时间变成「免检名单」—— 文件改名或改回注入以后，
    /// 剩下一条永远为真的豁免，而**没有任何外部信号**提示它已失效。
    @Test func theAllowListHasNoStaleEntries() throws {
        let root = RepositoryScan.repositoryRoot
        var liveReferences: Set<String> = []
        var missingFiles: [String] = []

        for (relativePath, _) in Self.allowedSharedReferrers {
            let url = root.appending(path: relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missingFiles.append(relativePath)
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            if RepositoryScan.codeLines(of: text).contains(where: { $0.text.contains("Container.shared") }) {
                liveReferences.insert(relativePath)
            }
        }

        #expect(
            missingFiles.isEmpty,
            "白名单指向的文件不存在（改名或删了）：\(missingFiles.joined(separator: ", "))"
        )

        let stale = Self.allowedSharedReferrers.keys.filter { !liveReferences.contains($0) }.sorted()
        #expect(
            stale.isEmpty,
            """
            白名单里这些条目已经不再引用 Container.shared 了，属于过期豁免，请删掉：
            \(stale.joined(separator: "\n"))
            """
        )
    }
}
