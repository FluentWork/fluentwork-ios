import FactoryKit
import Testing
@testable import FluentWorkCore

/// 测试进程**不该**构造真的 `LiveAudioEngine`。
///
/// `AppDependencies.audioEngine` 里有一道守卫，注释把目的写得很清楚：
///
/// > XCTest path: keep `PlaceholderAudioEngine` so unit tests that exercise
/// > reducer/middleware wiring without AVFoundation can still resolve
/// > `audioEngine()` without spinning up an `AVAudioEngine` graph.
///
/// 但它判的是 `XCTestConfigurationFilePath` —— 那是 **XCTest 的运行器**才会设的变量。
/// 本仓用的是 Swift Testing，跑法是 `swift test`，该变量为 `nil`（本机实测），
/// 于是这道守卫**从不生效**。
///
/// 后果不是「多构造一个对象」：真的 `LiveAudioEngine` 带着真的 `AVAudioSession`
/// 与真的麦克风，`deinit` 还会无条件去碰输入节点（`engine.inputNode.removeTap`）。
/// 全量测试里实测有 **37 条**测试因此构造了真引擎——而它们全是 corpus / review /
/// dailyRead / launch 这类**与音频无关**的接线测试，只是顺手解析了整个依赖图。
///
/// 这条测试钉的是**性质**（「测试进程里解析出来的必须是替身」），不是某种具体的
/// 守卫写法 —— 换个判据也照样成立。
@MainActor
@Test func testsResolveThePlaceholderAudioEngineRatherThanTheRealOne() {
    let container = Container()
    container.reset()

    let engine = container.audioEngine()

    #expect(
        engine is PlaceholderAudioEngine,
        """
        测试进程解析到了 \(type(of: engine))，而不是 PlaceholderAudioEngine。
        真的 LiveAudioEngine 会构造 AVAudioEngine 图，并在 deinit 里碰真输入节点。
        """
    )
}

/// 判据从「猜运行器」改成「跑测试的人自己说」之后，钉住这条契约。
///
/// CI 的 `swift test` 步骤设 `FLUENTWORK_TEST_PROCESS=1`，因为它那里的 SwiftPM 生成的是
/// 普通可执行文件、XCTest 没被加载 —— `AudioEngineResolutionTests` 在 runner 上红、
/// 在本机绿，就是这条分支缺失的直接后果（2026-09-29）。
///
/// ⚠️ 两个输入都是**参数**，这不只是风格：第一版只注入环境、`XCTestCase` 仍在函数里
/// 现查，于是**删掉整条 `FLUENTWORK_TEST_PROCESS` 分支判据照样绿**（本机 XCTest 已加载，
/// 落点永远在最后那条 `return`）—— 一条本机无法转红的假判据。自己的变异把它验出来了。
@Test func theTestProcessPredicateReadsAllThreeSignals() {
    // 生产：三个信号都没有 ⇒ 不是测试进程。这一侧以前根本没法断言。
    #expect(
        TestProcess.isTestProcess(environment: [:], xctestIsLoaded: false) == false,
        "没有任何信号时不许判成测试进程，否则生产会拿到替身音频引擎"
    )
    // CI：显式表态。
    #expect(
        TestProcess.isTestProcess(
            environment: ["FLUENTWORK_TEST_PROCESS": "1"],
            xctestIsLoaded: false
        ),
        "CI 显式说「我在跑测试」，就必须为真"
    )
    // `xcodebuild test` 的运行器：XCTest 在。
    #expect(TestProcess.isTestProcess(environment: [:], xctestIsLoaded: true))
    // 本机 `swift test` 的极早时刻：类还没加载，但变量已设。
    #expect(
        TestProcess.isTestProcess(
            environment: ["XCTestConfigurationFilePath": "/tmp/probe.xctestconfiguration"],
            xctestIsLoaded: false
        )
    )
}
