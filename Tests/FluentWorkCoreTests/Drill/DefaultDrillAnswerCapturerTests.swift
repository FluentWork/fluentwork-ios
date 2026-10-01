#if DEBUG
import Foundation
import Testing
@testable import FluentWorkCore

/// `DefaultDrillAnswerCapturer` —— 闪测「听一句话」那段**生产实现**。
///
/// 上面 `DrillFeatureTests` 里那几条用的是采集替身，验的是「中间件有没有去听、听到之后派什么」；
/// 这里验的是另一半：**它自己去听的时候，收的是不是对的那一句、什么时候停、会话有没有还**。
/// 两半都在，这条链才算有判据 —— 只有替身那半，等于「接线对了，被接的东西没人看过」。
@Suite("闪测采集（生产实现）")
struct DefaultDrillAnswerCapturerTests {

    /// 一次点击 = 一句话：收 PCM 到 `.speechEnded` 为止，把转写结果交回来。
    @Test("听一句话并返回转写：收尾等的是 .speechEnded，不是时钟")
    func oneUtteranceComesBackAsText() async throws {
        let harness = try makeCapturer(utterances: ["I'll ship it tomorrow."])

        let text = try await harness.capturer.captureAnswer(seconds: 5)

        #expect(text == "I'll ship it tomorrow.")
        // 60ms 的一句话必须在**远短于**限时的时刻就交回来；等满 5 秒说明收尾靠的是时钟。
        let elapsed = harness.elapsed()
        #expect(elapsed < 2, "限时 5 秒却花了 \(elapsed) 秒 —— 收尾没等 `.speechEnded`")
    }

    /// 转写只给出空白时返回 `nil`，**不是空串、更不是错误**。
    ///
    /// 空串会让中间件派一个 `.answerCaptured(asrText: "")`，屏幕上就成了「你刚说的是空的」；
    /// 而真相是没有可用的识别结果 —— 那该走 5 秒到点的兜底。
    /// （替身引擎一定会产出音频，所以「没有音频」那条路在单测里够不到；
    /// 够得到的是「音频来了、转写没给出东西」，而它是同一支分支。）
    @Test("转写结果只有空白时返回 nil，不返回空串")
    func blankTranscriptComesBackAsNil() async throws {
        let harness = try makeCapturer(utterances: ["   "])

        let text = try await harness.capturer.captureAnswer(seconds: 5)

        #expect(text == nil, "转写是空白却给了一个结果：\(String(describing: text))")
    }

    /// **起一次、还一次**：整轮只起一次采集，`stopListening()` 把音频会话的认领还回去。
    ///
    /// 不还的后果不是「没有声音」，是**别人的声音被关掉**（名册上那个名字等不到归还，
    /// 此后任何一次归还都判「还有人占着」）—— 所以这一对必须有人钉。
    @Test("整轮只起一次采集；stopListening 把认领还回去")
    func listeningStartsOnceAndIsHandedBack() async throws {
        let harness = try makeCapturer(utterances: ["one", "two"])

        _ = try await harness.capturer.captureAnswer(seconds: 5)
        _ = try await harness.capturer.captureAnswer(seconds: 5)
        let startsWhileRunning = await harness.engine.startCaptureCalls
        #expect(startsWhileRunning == 1, "第二次听的时候又起了一次采集（真引擎会拆了重装 tap）")

        await harness.capturer.stopListening()
        #expect(await harness.engine.stopCaptureCalls == 1)
        #expect(
            await harness.playback.releaseSessionClaimCalls == 1,
            "没有把音频会话的认领还回去 —— 名册上会永远挂着一个名字"
        )

        // 收尾再叫一次是幂等的：不能变成第二次归还（第二次归还判「没人占着」，是另一条路）。
        await harness.capturer.stopListening()
        #expect(await harness.playback.releaseSessionClaimCalls == 1)
    }

    // MARK: - 装置

    private struct Harness {
        let capturer: DefaultDrillAnswerCapturer
        let engine: MockAudioEngine
        let playback: ClaimRecordingPlaybackEngine
        let startedAt: ContinuousClock.Instant

        func elapsed() -> Double {
            let d = startedAt.duration(to: ContinuousClock.now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
    }

    private func makeCapturer(
        utterances: [String],
        utteranceDuration: Duration = .milliseconds(60)
    ) throws -> Harness {
        let playback = ClaimRecordingPlaybackEngine()
        let engine = MockAudioEngine(
            script: MockAudioEngine.Script(
                utteranceDuration: utteranceDuration,
                chunkInterval: .milliseconds(20)
            ),
            playback: playback
        )
        let capturer = DefaultDrillAnswerCapturer(
            audioEngine: engine,
            transcriber: ScriptedClientASRTranscriber(
                script: ScriptedClientASRTranscriber.Script(utterances: utterances)
            )
        )
        return Harness(
            capturer: capturer,
            engine: engine,
            playback: playback,
            startedAt: ContinuousClock.now
        )
    }
}

/// 采集替身的播放那一半：只记账。
private final class ClaimRecordingPlaybackEngine: AudioEngineProtocol, @unchecked Sendable {
    private(set) var releaseSessionClaimCalls = 0

    private nonisolated let stream = AsyncStream<AudioEngineEvent> { $0.finish() }
    private nonisolated let captureStream = AsyncStream<AudioEngineEvent> { $0.finish() }

    func startCapture() async throws {}
    func stopCapture() async {}
    func releaseSessionClaim() async { releaseSessionClaimCalls += 1 }
    nonisolated func events() -> AsyncStream<AudioEngineEvent> { stream }
    nonisolated func captureEventStream() -> AsyncStream<AudioEngineEvent> { captureStream }
    func play(pcm: Data) async {}
    func interruptNow() async {}
    func discardActiveSpeech() async {}
}
#endif
