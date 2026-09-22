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
