#if DEBUG
import Foundation
import os
import Testing
import FluentWorkNetworking
@testable import FluentWorkCore

/// `MockAudioEngine` 是「真机验证不再依赖真麦克风」的那件工具，所以它的契约
/// 要钉死：一次点击 = 恰好一轮、收尾只发生一次、丢弃不产生空轮次。
/// 它自己撒谎的话，用它验出来的结论也是假的。
@Suite("MockAudioEngine（麦克风替身）")
struct MockAudioEngineTests {

    @Test("一次点击 = 一轮：speechStarted → 若干 PCM 块 → speechEnded")
    func tapProducesOneUtterance() async {
        let engine = MockAudioEngine(
            script: MockAudioEngine.Script(utteranceDuration: .milliseconds(60), chunkInterval: .milliseconds(20)),
            playback: RecordingPlaybackEngine()
        )
        let stream = engine.events()

        await engine.beginManualSpeech()
        let events = await collect(stream, stoppingAt: .speechEnded)

        #expect(events.first == .speechStarted)
        #expect(events.last == .speechEnded)

        let chunks = events.compactMap { event -> Data? in
            if case let .pcmChunk(data) = event { return data }
            return nil
        }
        #expect(chunks.count == 3, "60ms / 20ms = 3 块；实际 \(chunks.count)")
        #expect(
            chunks.allSatisfy { $0.count == 640 },
            "每块必须是 20ms 的 16kHz PCM16（640 字节、偶数），否则客户端会按奇数长度丢掉"
        )
    }

    @Test("endManualSpeech 提前收尾，且整轮只发一次 speechEnded")
    func manualEndClosesTheUtteranceOnce() async {
        let engine = MockAudioEngine(
            script: MockAudioEngine.Script(utteranceDuration: .seconds(5), chunkInterval: .milliseconds(20)),
            playback: RecordingPlaybackEngine()
        )
        let stream = engine.events()

        await engine.beginManualSpeech()
        await engine.endManualSpeech()

        // 窗口覆盖「脚本任务本该发下一块」的时刻：收尾若来自两条路
        // （手动收尾 + 脚本跑完），这里会数到两个。
        let events = await collect(stream, within: .milliseconds(120))
        #expect(events.contains(.speechStarted))
        #expect(
            events.filter { $0 == .speechEnded }.count == 1,
            "一收尾就取消脚本，晚到的那次不该再发一遍"
        )
    }

    @Test("discardActiveSpeech 丢句但不发 speechEnded（否则会给网关送空轮次）")
    func discardDoesNotEndTheUtterance() async {
        let engine = MockAudioEngine(
            script: MockAudioEngine.Script(utteranceDuration: .seconds(5), chunkInterval: .milliseconds(20)),
            playback: RecordingPlaybackEngine()
        )
        let stream = engine.events()

        await engine.beginManualSpeech()
        await engine.discardActiveSpeech()

        let events = await collect(stream, within: .milliseconds(120))
        #expect(events.contains(.speechStarted))
        #expect(
            !events.contains(.speechEnded),
            "丢弃不能收尾：那会给网关送一个没有音频的轮次"
        )
    }

    @Test("autoRepeat：不用点击也会自己说话（无人值守）")
    func autoRepeatSpeaksWithoutATap() async {
        let engine = MockAudioEngine(
            script: MockAudioEngine.Script(
                utteranceDuration: .milliseconds(20),
                chunkInterval: .milliseconds(20),
                autoRepeat: .milliseconds(40)
            ),
            playback: RecordingPlaybackEngine()
        )
        let stream = engine.events()
        try? await engine.startCapture()

        var endings = 0
        for await event in stream where event == .speechEnded {
            endings += 1
            if endings >= 2 { break }
        }
        #expect(endings == 2)
        await engine.stopCapture()
    }

    @Test("fromEnvironment：没设 FW_MOCK_MIC 就不生效（默认是关的）")
    func scriptIsOffByDefault() {
        #expect(MockAudioEngine.Script.fromEnvironment([:]) == nil)
        #expect(MockAudioEngine.Script.fromEnvironment(["FW_MOCK_MIC": "0"]) == nil)
        #expect(MockAudioEngine.Script.fromEnvironment(["FW_MOCK_MIC": ""]) == nil)
    }

    @Test("fromEnvironment：解析时长与自动周期")
    func scriptReadsEnvironment() {
        let script = MockAudioEngine.Script.fromEnvironment([
            "FW_MOCK_MIC": "1",
            "FW_MOCK_MIC_UTTERANCE_MS": "800",
            "FW_MOCK_MIC_AUTO_MS": "3000",
        ])
        #expect(script?.utteranceDuration == .milliseconds(800))
        #expect(script?.autoRepeat == .milliseconds(3000))

        let manualOnly = MockAudioEngine.Script.fromEnvironment(["FW_MOCK_MIC": "1"])
        #expect(manualOnly?.utteranceDuration == .milliseconds(1500))
        #expect(manualOnly?.autoRepeat == nil, "不设 AUTO 就不该自己说话")
    }

    @Test("采集开始只配播放会话，不配 .playAndRecord（麦克风不会一直亮着）")
    func startCapturePreparesAPlaybackOnlySession() async throws {
        let counter = CallCounter()
        let engine = MockAudioEngine(
            script: MockAudioEngine.Script(),
            playback: RecordingPlaybackEngine(),
            preparePlaybackSession: { counter.increment() }
        )

        try await engine.startCapture()
        #expect(counter.count == 1, "会话必须被配成播放：否则系统一直显示麦克风在用")
    }

    @Test("采集被替掉，播放仍转发给真引擎")
    func playbackIsForwarded() async {
        let playback = RecordingPlaybackEngine()
        let engine = MockAudioEngine(script: MockAudioEngine.Script(), playback: playback)

        await engine.play(pcm: Data([0x01, 0x02]))
        await engine.play(frame: WSAudioFrame(sequence: 3, payload: Data([0x03, 0x04])))
        await engine.interruptNow()

        #expect(await playback.pcmCalls == [Data([0x01, 0x02])])
        #expect(await playback.frameCalls.map(\.sequence) == [3])
        #expect(await playback.interruptCalls == 1)
    }
}

// MARK: - 测试辅助

/// 收集事件直到出现某个事件为止；`AsyncStream` 不会结束，读到目标就退出迭代。
/// 只用于「某个事件一定会来」的用例。
private func collect(
    _ stream: AsyncStream<AudioEngineEvent>,
    stoppingAt target: AudioEngineEvent
) async -> [AudioEngineEvent] {
    var events: [AudioEngineEvent] = []
    for await event in stream {
        events.append(event)
        if event == target { break }
    }
    return events
}

/// 在时间窗内尽量收集事件，窗口一到就返回。
///
/// 验「**不该**发生的事」必须用它：直接 `for await` 等一个按契约不会到来的事件，
/// 测试会挂死而不是失败 —— 挂死的测试比失败的测试更糟，它把整轮 CI 一起拖住。
/// 反过来，「收集完之后再 sleep 断言旧数组」也不行：晚到的事件根本进不了那个数组，
/// 断言永远成立。要验「没有第二个」，就得让窗口把「晚」也覆盖进去。
private func collect(
    _ stream: AsyncStream<AudioEngineEvent>,
    within timeout: Duration
) async -> [AudioEngineEvent] {
    let box = EventBox()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in stream { await box.append(event) }
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
        }
        await group.next()
        group.cancelAll()
    }
    return await box.events
}

private actor EventBox {
    private(set) var events: [AudioEngineEvent] = []
    func append(_ event: AudioEngineEvent) {
        events.append(event)
    }
}

/// 给**同步**闭包计数的盒子（`preparePlaybackSession` 不能 await）。
private final class CallCounter: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)

    var count: Int {
        storage.withLock { $0 }
    }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

private actor RecordingPlaybackEngine: AudioEngineProtocol {
    private(set) var pcmCalls: [Data] = []
    private(set) var frameCalls: [WSAudioFrame] = []
    private(set) var interruptCalls = 0

    private nonisolated let stream = AsyncStream<AudioEngineEvent> { $0.finish() }

    func startCapture() async throws {}
    func stopCapture() async {}
    nonisolated func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }
    func play(frame: WSAudioFrame) async {
        frameCalls.append(frame)
    }
    func play(pcm: Data) async {
        pcmCalls.append(pcm)
    }
    func interruptNow() async {
        interruptCalls += 1
    }
    func discardActiveSpeech() async {}
}
#endif
