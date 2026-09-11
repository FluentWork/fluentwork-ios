import FactoryKit
import FluentWorkDiagnostics
import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKit
import TGReduxKitTesting
@testable import FluentWorkCore

// MARK: - SpeechSessionMiddleware Unit Tests

/// Tests for the pure functions and data structures in SpeechSessionMiddleware.
///
/// These tests cover:
/// 1. `pendingTurnID` - the turn ID computation for end-of-utterance events
/// 2. `TurnCountBox` - the Sendable wrapper for cross-actor turn counting
@Suite("SpeechSessionMiddleware Unit Tests")
struct SpeechSessionMiddlewareTests {

    // MARK: - pendingTurnID Tests

    @Test func pendingTurnIDReturnsTurnNForVadSpeechEnd() {
        let turnID = pendingTurnID(for: .vadSpeechEnd(turnID: nil), currentCount: 0)
        #expect(turnID == "turn-1")
    }

    @Test func pendingTurnIDReturnsTurnNPlusOneForVadSpeechEnd() {
        let turnID = pendingTurnID(for: .vadSpeechEnd(turnID: nil), currentCount: 5)
        #expect(turnID == "turn-6")
    }

    @Test func pendingTurnIDReturnsTurnNForHoldEnd() {
        let turnID = pendingTurnID(for: .holdEnd(turnID: nil), currentCount: 2)
        #expect(turnID == "turn-3")
    }

    @Test func pendingTurnIDReturnsNilForSessionStartTap() {
        let turnID = pendingTurnID(for: .sessionStartTap, currentCount: 0)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForSocketReady() {
        let turnID = pendingTurnID(for: .socketReady, currentCount: 0)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForVadSpeechStart() {
        let turnID = pendingTurnID(for: .vadSpeechStart, currentCount: 3)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForNetworkLost() {
        let turnID = pendingTurnID(for: .networkLost, currentCount: 0)
        #expect(turnID == nil)
    }

    @Test func pendingTurnIDReturnsNilForFailed() {
        let turnID = pendingTurnID(for: .failed("test error"), currentCount: 10)
        #expect(turnID == nil)
    }

    // MARK: - TurnCountBox Tests

    @Test func turnCountBoxInitializesWithZero() {
        let box = TurnCountBox()
        #expect(box.get() == 0)
    }

    @Test func turnCountBoxSetUpdatesValue() {
        let box = TurnCountBox()
        box.set(5)
        #expect(box.get() == 5)
    }

    @Test func turnCountBoxOverridesPreviousValue() {
        let box = TurnCountBox()
        box.set(3)
        box.set(7)
        #expect(box.get() == 7)
    }

    @Test func turnCountBoxGetDoesNotModifyValue() {
        let box = TurnCountBox()
        box.set(42)
        _ = box.get()
        #expect(box.get() == 42)
    }

    @Test func turnCountBoxIsSendable() {
        let box = TurnCountBox()
        func acceptSendable(_ box: TurnCountBox) -> Bool {
            return true
        }
        #expect(acceptSendable(box) == true)
    }

    /// A gate that was never opened must not egress PCM. The microphone tap
    /// runs from `startCapture()` onward, so audio captured before the user
    /// opens a turn used to reach the provider and be committed into the
    /// *next* turn's transcript.
    @Test func speechCaptureGateDoesNotForwardPCMBeforeFirstSpeech() {
        let gate = SpeechCaptureGate()
        #expect(!gate.isOpen)
        #expect(!gate.shouldForwardPCM)
    }

    @Test func speechCaptureGateDropsPCMAfterAbortUntilNextSpeech() {
        let gate = SpeechCaptureGate()
        #expect(!gate.shouldForwardPCM)
        #expect(!gate.isOpen)

        gate.beginSpeech()
        #expect(gate.isOpen)
        #expect(gate.shouldForwardPCM)

        gate.abort()
        #expect(!gate.isOpen)
        #expect(!gate.shouldForwardPCM)

        gate.beginSpeech()
        #expect(gate.isOpen)
        #expect(gate.shouldForwardPCM)
    }

    @Test func evaluationArrivalBoxConsumeClearsMark() {
        let box = EvaluationArrivalBox()
        #expect(!box.consume())
        box.mark()
        #expect(box.consume())
        #expect(!box.consume())
    }

    @Test func evaluationArrivalBoxResetDropsPendingBadge() {
        let box = EvaluationArrivalBox()
        box.mark()
        box.reset()
        #expect(!box.consume())
    }

    /// PCM egress ends with the turn. The gateway commits its provider buffer
    /// on `user.speech.end`, so anything forwarded after that is transcribed
    /// into the *next* turn — the defect behind a 83-character transcript
    /// coming back from a 2.9s tap.
    @Test func speechCaptureGateEndSpeechStopsPCM() {
        let gate = SpeechCaptureGate()
        gate.beginSpeech()
        #expect(gate.shouldForwardPCM)

        gate.endSpeech()
        #expect(!gate.isOpen)
        #expect(!gate.shouldForwardPCM)
    }

    /// The inter-turn gap is the regression window: PCM captured there used to
    /// be forwarded and committed together with the following turn.
    @Test func speechCaptureGateForwardsPCMOnlyInsideTheOpenTurn() {
        let gate = SpeechCaptureGate()

        #expect(!gate.shouldForwardPCM) // before any turn

        gate.beginSpeech()
        #expect(gate.shouldForwardPCM)
        gate.endSpeech()
        #expect(!gate.shouldForwardPCM)
        #expect(!gate.shouldForwardPCM) // gap between turns

        gate.beginSpeech()
        #expect(gate.shouldForwardPCM)
        gate.endSpeech()
        #expect(!gate.shouldForwardPCM)
    }

    /// Middleware `set(userTurnCount)` vs audio-loop `get()+1` for `turn-N`.
    /// Individual get/set are atomic; writes of increasing counts never appear
    /// to go backwards to a concurrent reader.
    @Test func turnCountBoxAudioLoopSeesMonotonicWrites() async {
        let box = TurnCountBox()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for count in 1...64 {
                    box.set(count)
                }
            }
            group.addTask {
                var last = 0
                for _ in 0..<2_000 {
                    let value = box.get()
                    #expect(value >= last)
                    #expect((0...64).contains(value))
                    last = value
                }
            }
        }

        #expect(box.get() == 64)
    }

    /// Recording-timeout abort vs audio-loop PCM / `speechEnded` readers.
    /// After abort settles, trailing `endSpeech` must still drop PCM until
    /// the next `beginSpeech`.
    @Test func speechCaptureGateAbortRacesAudioLoopReaders() async {
        let gate = SpeechCaptureGate()
        gate.beginSpeech()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { gate.abort() }
            for _ in 0..<32 {
                group.addTask {
                    _ = gate.isOpen
                    _ = gate.shouldForwardPCM
                }
            }
        }

        #expect(!gate.isOpen)
        #expect(!gate.shouldForwardPCM)

        gate.endSpeech()
        #expect(!gate.shouldForwardPCM)

        gate.beginSpeech()
        #expect(gate.isOpen)
        #expect(gate.shouldForwardPCM)
    }

    /// B15: timeout task `arm` and a second scheduler must not both succeed.
    @Test func turnTimeoutTrackingConcurrentArmSucceedsOnce() async {
        let tracking = TurnTimeoutTracking()
        let successes = SuccessCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    if tracking.arm() {
                        await successes.increment()
                    }
                }
            }
        }

        #expect(await successes.value == 1)
        #expect(tracking.isArmed)
    }

    /// `ai.turn.end` disarm vs 70s timeout disarm: both may run; armed must
    /// end false, and a later turn can arm again.
    @Test func turnTimeoutTrackingDisarmRacesLeaveUnarmed() async {
        let tracking = TurnTimeoutTracking()
        #expect(tracking.arm())

        await withTaskGroup(of: Void.self) { group in
            group.addTask { tracking.disarm() }
            group.addTask { tracking.disarm() }
        }

        #expect(!tracking.isArmed)
        #expect(tracking.arm())
        tracking.disarm()
        #expect(!tracking.isArmed)
    }

    /// Transport loop records Opus frames; `ai.tts.start` resets. Concurrent
    /// increments must not drop counts.
    @Test func ttsStreamTraceConcurrentRecordAudioCountsEveryFrame() async {
        let trace = TTSStreamTrace()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { _ = trace.recordAudio() }
            }
        }

        #expect(trace.audioFrameCount() == 32)
        trace.reset()
        #expect(trace.audioFrameCount() == 0)
    }
}

private actor SuccessCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - SpeechSessionMiddleware Integration Tests

/// Integration tests for the full middleware behavior with server-side ASR (B14).
///
/// These tests verify:
/// 1. Server ASR transcript handling via `serverASRReceived`
/// 2. NO phantom `sendSpeechBoundary` call when server ASR arrives (regression: the
///    original iOS VAD is the single source of truth for `user.speech.end`; emitting
///    another one here starts a ghost turn with no audio and the gateway hangs for 60s.)
/// 3. Degraded text message handling
/// 4. Transition telemetry emission
/// `.serialized` because these tests register stubs into `Container`, whose
/// `.shared` / `.singleton` scopes cache process-wide: two of them running at
/// once can resolve each other's stub, and the loser's `emit` then goes to an
/// engine nobody is reading. Serializing is what "these tests mutate global
/// state" should look like — not a workaround for it.
@Suite("SpeechSessionMiddleware B14 Integration", .serialized)
struct SpeechSessionMiddlewareB14Tests {

    // MARK: - Server ASR Tests

    @MainActor
    @Test func serverASRDispatchesTranscriptUpdateViaReducer() async throws {
        // Note: serverASRReceived can be dispatched two ways:
        // 1. As .session(.serverASRReceived) - advances the ASR → LLM stage
        // 2. As .serverASRReceived directly - handled by reducer to update liveTranscript
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Connect first
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Dispatch serverASR directly (not wrapped in .session) for reducer to handle
        store.dispatch(.speakingRoom(.serverASRReceived(text: "这是服务器转写结果", turnID: "turn-1")))

        // Give time for reducer to update state
        try await Task.sleep(for: .milliseconds(100))

        // Verify liveTranscript was updated by the reducer
        #expect(store.state.speakingRoom.liveTranscript == "这是服务器转写结果")
    }

    @MainActor
    @Test func serverASRFromTransportDoesNotResendSpeechBoundary() async throws {
        // Regression: previously the middleware called `sendSpeechBoundary` on receipt
        // of `client.asr.transcription` for badge hit detection. That caused a phantom
        // second turn at the gateway — the VAD-fired `user.speech.end` already produced
        // the transcript, so a second one in 16ms committed empty audio and the gateway
        // timed out at 60s, surfacing "sockettransporterror error 3" on the client.
        // The authoritative transcript for badge detection now comes from
        // `ProviderOutbound.ServerASRText` on the backend side; the iOS layer must not
        // re-emit a `user.speech.end` here.
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Connect so we can receive transport events
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Emit server ASR via transport event.
        speechClient.emit(.control(.clientASRTranscription(text: "Transport transcript", turnID: "turn-1")))

        // Give the middleware a beat to process the transport event.
        try await Task.sleep(for: .milliseconds(150))

        // The middleware must NOT have re-fired sendSpeechBoundary for the relay frame.
        let boundaryCallCount = await speechClient.getBoundaryCallCount()
        #expect(boundaryCallCount == 0)
    }

    @MainActor
    @Test func serverASRFromTransportAdvancesProcessingASRToLLMWithoutResendingBoundary() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        let boundariesAfterVAD = await speechClient.getBoundaryCallCount()
        speechClient.emit(.control(.clientASRTranscription(text: "Transport transcript", turnID: "turn-1")))
        try await waitForProcessingStage(store, stage: .llm, timeout: 1_000_000_000)

        #expect(store.state.speakingRoom.liveTranscript == "Transport transcript")
        #expect(await speechClient.getBoundaryCallCount() == boundariesAfterVAD)
    }

    @MainActor
    @Test func recordingTimeoutSendsClientTurnAbortAndKeepsSessionAlive() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.recordingTimedOut)))
        try await waitForProcessingStage(store, stage: .aiAnswer, timeout: 1_000_000_000)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.getTurnAbortCalls().count == 1
        }

        let aborts = await speechClient.getTurnAbortCalls()
        #expect(aborts.count == 1)
        #expect(aborts.first?.turnID == "turn-1")
        #expect(aborts.first?.outcome == .timeout)
        #expect(await speechClient.getEndBoundaries().isEmpty)
        #expect(await speechClient.endSessionCalled == false)
        #expect(store.state.speakingRoom.phase == .processing)
        #expect(store.state.speakingRoom.processingStage == .aiAnswer)
        #expect(store.state.speakingRoom.session.failureReason == nil)

        audioEngine.emit(.speechEnded)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speechClient.getEndBoundaries().isEmpty)
        #expect(store.state.speakingRoom.phase == .processing)
        #expect(store.state.speakingRoom.processingStage == .aiAnswer)

        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        #expect(store.state.speakingRoom.phase == .recording)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await speechClient.endSessionCalled == false)
    }

    @MainActor
    @Test func feedbackBadgeLeavesWaitingForEvaluationWithoutFailing() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil)))
        try await waitForProcessingStage(store, stage: .evaluation, timeout: 1_000_000_000)

        speechClient.emit(.control(.feedbackBadge(
            badge: "表达自然",
            phraseBlockID: "block-1",
            tier: .soft,
            turnID: "turn-1"
        )))
        try await waitForPhase(store, phase: .waitingUser, timeout: 1_000_000_000)

        #expect(store.state.speakingRoom.phase == .waitingUser)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(store.state.speakingRoom.lastBadge == "表达自然")
        #expect(await speechClient.endSessionCalled == false)
    }

    @MainActor
    @Test func feedbackBadgeBeforeTurnEndLeavesEvaluationWaitImmediately() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        speechClient.emit(.control(.feedbackBadge(
            badge: "ship it",
            phraseBlockID: "block-2",
            tier: .highlight,
            turnID: "turn-1"
        )))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.lastBadge == "ship it"
        }
        #expect(store.state.speakingRoom.phase == .processing)
        #expect(store.state.speakingRoom.processingStage == .asr)

        speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil)))
        try await waitForPhase(store, phase: .waitingUser, timeout: 1_000_000_000)

        #expect(store.state.speakingRoom.phase == .waitingUser)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await speechClient.endSessionCalled == false)
    }

    @MainActor
    @Test func evaluationTimedOutReturnsToWaitingUserWithoutEndingSession() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil)))
        try await waitForProcessingStage(store, stage: .evaluation, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.evaluationTimedOut)))
        try await waitForPhase(store, phase: .waitingUser, timeout: 1_000_000_000)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await audioEngine.interruptCalls >= 1
        }

        #expect(store.state.speakingRoom.phase == .waitingUser)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await speechClient.endSessionCalled == false)
        #expect(await audioEngine.interruptCalls >= 1)
    }

    /// A processing sub-stage budget overrun is a diagnostic, not a verdict.
    ///
    /// The budgets are 15s (ASR) / 45s (LLM) / 30s (review), while the gateway
    /// waits 60s for the vendor. Killing the session on the client's budget made
    /// the server's budget unreachable: every turn where the vendor took longer
    /// than 15s died on the client even though the server would have answered.
    /// Observed on a physical device on 2026-09-11 — the gateway was still
    /// inside collectTurn at 60s when the client had already given up at 15.9s.
    ///
    /// The budget is injected so the overrun is observable in milliseconds; the
    /// real 15s is why this path had no coverage at all.
    /// The connection's reader is built once per store, not once per session.
    ///
    /// `AsyncStream` is a single-consumer sequence and the transport's stream
    /// lives as long as the transport, so asking for it again on every session
    /// start leaves a dying iterator competing with the live one for the same
    /// events — and the `.cancel(id: transportEvents)` that `.endSession` used
    /// to dispatch could land on the *next* session's consumer, which then
    /// exits without a trace.
    ///
    /// On device that presented as a room stuck on 「连接中」: the consumer
    /// started and exited 159ms later while the socket was up and the client
    /// was writing to it successfully.
    ///
    /// Driven start → end → re-enter, the old shape does not merely look wrong,
    /// it **hangs**: the second session never reaches `.aiSpeaking`, and the
    /// wait times out. Verified against the pre-change middleware, where the
    /// failure lands on the second session's `waitForPhase(.aiSpeaking)`.
    ///
    /// The test drives it deterministically rather than racing: `.endSession`
    /// dispatches `.cancel(id: transportEvents)` as an effect, and a re-entry
    /// that follows within the same instant starts the next session's consumer
    /// before that cancellation lands — so the cancellation kills the *new*
    /// reader. On device the same window is a few hundred milliseconds and the
    /// user re-enters by hand, which is why it only sometimes failed there.
    @MainActor
    @Test func transportReaderIsBuiltOncePerStoreNotOncePerSession() async throws {
        let container = Container()
        container.reset()
        container.processingTimeouts.register { ProcessingTimeouts(connectWait: .seconds(5)) }
        defer { container.processingTimeouts.register { .standard } }
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)

        // Session 1 — start, connect, then end it.
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        speechClient.emit(.stateChanged(.connected))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.endTap)))
        try await waitForPhase(store, phase: .ended, timeout: 1_000_000_000)

        // Session 2 — leave and re-enter, exactly the flow that failed.
        store.dispatch(.speakingRoom(.applySession(.initial)))
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        speechClient.emit(.stateChanged(.connected))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        #expect(
            speechClient.transportEventsRequestCount == 1,
            "the reader belongs to the connection; one per session leaves competing iterators over one stream"
        )
    }

    /// The engine's reader has to survive a session ending too.
    ///
    /// Same shape as the transport's, same failure: the engine's `events` stream
    /// lives as long as the engine, but the consumer was built by
    /// `.createSession` and cancelled by `.endSession`. Measured on device, on
    /// the first re-entered session: tapping 「开始说话」 did nothing at all.
    /// `beginManualSpeech()` reached the engine and it emitted `.speechStarted`
    /// — into a stream nobody was reading, so the machine stayed on
    /// `waitingUser` and the tap looked like it had failed.
    @MainActor
    @Test func audioReaderSurvivesSessionEnd() async throws {
        let container = Container()
        container.reset()
        container.processingTimeouts.register { ProcessingTimeouts(connectWait: .seconds(5)) }
        defer { container.processingTimeouts.register { .standard } }
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)

        // Session 1 — connect, then end it.
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        speechClient.emit(.stateChanged(.connected))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.endTap)))
        try await waitForPhase(store, phase: .ended, timeout: 1_000_000_000)

        // Session 2 — re-enter and connect.
        store.dispatch(.speakingRoom(.applySession(.initial)))
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        speechClient.emit(.stateChanged(.connected))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // The tap: the engine reports speech starting. Nothing else carries it.
        audioEngine.emit(.speechStarted)
        do {
            try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        } catch {
            Issue.record("stuck at \(store.state.speakingRoom.phase) after emitting speechStarted")
            throw error
        }
    }

    /// Every session begins in `.connecting`, and nothing bounded it. The ASR /
    /// LLM / review / evaluation / recording / reconnect / turn timers all start
    /// later, so a connect that never delivered `.socketReady` — the transport
    /// emitted nothing, the handshake stalled, a race ate the event — left the
    /// room showing 「连接中」 with no timeout, no error, and no way forward but
    /// backing out of the screen.
    @MainActor
    @Test func connectingPhaseTimesOutInsteadOfStrandingTheRoom() async throws {
        let container = Container()
        container.reset()
        container.processingTimeouts.register {
            ProcessingTimeouts(connectWait: .milliseconds(80))
        }
        defer {
            // `processingTimeouts` is a `.singleton`. Leaving an 80ms connect
            // budget registered hands the next test a room that fails to
            // connect before it dispatches `.socketReady` — and nothing in that
            // test says why. Restore the real budget on the way out.
            container.processingTimeouts.register { .standard }
        }
        container.audioEngine.register { StubAudioEngineForMiddleware() }
        container.speechSessionClient.register { StubSpeechSessionClientForMiddleware() }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // The stub transport never produces `.socketReady`. Without a watchdog
        // this is where the room stays.
        try await waitForPhase(store, phase: .failed, timeout: 2_000_000_000)
        #expect(store.state.speakingRoom.failureReason != nil)
    }

    @MainActor
    @Test func processingSubStageTimeoutDoesNotFailTheSession() async throws {
        let container = Container()
        container.reset()
        container.processingTimeouts.register {
            ProcessingTimeouts(
                asr: .milliseconds(80),
                llm: .milliseconds(80),
                review: .milliseconds(80),
                totalCap: .seconds(30),
                evaluationWait: .seconds(30)
            )
        }
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        // Several times the injected ASR budget. No ai.turn.end arrives, so the
        // only thing that could end this turn is a timeout.
        try await Task.sleep(for: .milliseconds(400))

        #expect(store.state.speakingRoom.phase == .processing)
        #expect(store.state.speakingRoom.processingStage == .asr)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await speechClient.endSessionCalled == false)
    }

    /// The sub-stage timers hand off when the pipeline advances.
    ///
    /// After the processing phases merged, that advance is a **stage** change
    /// rather than a phase change — so the handoff keys on the stage, and
    /// nothing in the phase machinery would notice if it stopped happening.
    /// A missed handoff leaves the ASR budget counting into the LLM stage
    /// (a spurious `processing_timeout_asr`) and never arms the LLM budget,
    /// which is silent: the overrun it exists to report simply never arrives.
    ///
    /// Both halves are asserted, in the order they can be observed: past the
    /// ASR budget but before the LLM one, then past both.
    @MainActor
    @Test func pipelineAdvanceHandsTheSubStageTimerFromASRToLLM() async throws {
        let container = Container()
        container.reset()
        container.processingTimeouts.register {
            ProcessingTimeouts(
                asr: .milliseconds(80),
                llm: .milliseconds(400),
                review: .milliseconds(400),
                totalCap: .seconds(30),
                evaluationWait: .seconds(30)
            )
        }
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }
        container.tracker.register { tracker }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        // The hop under test. `.processing` stays put; only the stage moves.
        speechClient.emit(.control(.clientASRTranscription(text: "hello", turnID: "turn-1")))
        try await waitForProcessingStage(store, stage: .llm, timeout: 1_000_000_000)

        // Past the ASR budget (80ms), still inside the LLM budget (400ms).
        try await Task.sleep(for: .milliseconds(220))
        #expect(
            tracker.events.filter { $0.name == "processing_timeout_asr" }.isEmpty,
            "the ASR budget kept running into the LLM stage — the handoff did not cancel it"
        )

        // Past the LLM budget: the timer armed by the handoff must fire.
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            tracker.events.contains { $0.name == "processing_timeout_llm" }
        }
    }

    @MainActor
    @Test func routeChangedReconfiguresCaptureWithoutChangingPhase() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        audioEngine.emit(.routeChanged("oldDeviceUnavailable"))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await audioEngine.reconfigureCalls == 1
        }

        #expect(store.state.speakingRoom.phase == .aiSpeaking)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await audioEngine.reconfigureCalls == 1)
    }

    @MainActor
    @Test func reconnectDuringProcessingDiscardsTurnWhenSocketReady() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.networkLost)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.session.isReconnecting
        }
        #expect(store.state.speakingRoom.phase == .processing)
        #expect(store.state.speakingRoom.processingStage == .asr)

        speechClient.emit(.stateChanged(.connected))
        try await waitForPhase(store, phase: .waitingUser, timeout: 1_000_000_000)

        #expect(store.state.speakingRoom.phase == .waitingUser)
        #expect(store.state.speakingRoom.session.isReconnecting == false)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await speechClient.endSessionCalled == false)
    }

    @MainActor
    @Test func manualSpeechBoundariesDriveRecordingWithoutEndingSession() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.manualSpeechBegin))
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        #expect(store.state.speakingRoom.phase == .recording)

        store.dispatch(.speakingRoom(.manualSpeechEnd))
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)
        #expect(store.state.speakingRoom.phase == .processing)
        #expect(store.state.speakingRoom.processingStage == .asr)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await speechClient.endSessionCalled == false)
        let boundaries = await speechClient.getEndBoundaries()
        #expect(boundaries.last?.turnID == "turn-1")
    }

    @MainActor
    @Test func aiTurnEndOutcomeTimeoutFailsSessionWithTurnTimeout() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        speechClient.emit(
            .control(.aiTurnEnd(turnID: "turn-1", outcome: .timeout, logID: "volc-timeout"))
        )
        try await waitForPhase(store, phase: .failed, timeout: 1_000_000_000)

        #expect(store.state.speakingRoom.failureReason == "turn_timeout")
        #expect(store.state.speakingRoom.phase == .failed)
        #expect(await speechClient.endSessionCalled == true)
    }

    @MainActor
    @Test func bootstrapAITurnEndOutcomeOkReturnsToWaitingUser() async throws {
        // DevEcho / Volc Start() send ai.turn.end outcome=ok before the user
        // speaks. Must not enter waitingForEvaluation ("正在评价").
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        #expect(store.state.speakingRoom.session.userTurnCount == 0)

        speechClient.emit(
            .control(.aiTurnEnd(turnID: "bootstrap", outcome: .ok, logID: nil))
        )
        try await waitForPhase(store, phase: .waitingUser, timeout: 1_000_000_000)

        #expect(store.state.speakingRoom.phase == .waitingUser)
        #expect(store.state.speakingRoom.failureReason == nil)
        #expect(await speechClient.endSessionCalled == false)
    }

    @MainActor
    @Test func degradedTextSendTextMessageEffect() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Enter degraded mode
        store.dispatch(.speakingRoom(.session(.networkDegraded)))
        try await waitForPhase(store, phase: .degradedText, timeout: 1_000_000_000)

        // Send text message
        speechClient.setSendDegradedTextMessageResult(.success(PostMessageResponse(sessionID: "s-1", reply: "AI回复", channel: "text", generator: "stub")))
        store.dispatch(.speakingRoom(.session(.textMessageSent)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.degradedTextMessageSent
        }

        #expect(await speechClient.degradedTextMessageSent)
    }

    // MARK: - Transition Telemetry Tests

    @MainActor
    @Test func transitionTelemetryEmittedOnPhaseChange() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }
        container.tracker.register { tracker }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // Give time for async track call to complete
        try await Task.sleep(for: .milliseconds(100))

        // Check idle → connecting transition
        let allEvents = tracker.events
        let transitionEvents = allEvents.filter {
            $0.name == "speech_session_transition"
        }

        #expect(transitionEvents.count >= 1)

        let idleToConnectingEvent = transitionEvents.first {
            $0.properties["from"] == "idle" &&
            $0.properties["to"] == "connecting"
        }
        #expect(idleToConnectingEvent != nil)

        // Socket ready: connecting → aiSpeaking
        store.dispatch(.speakingRoom(.session(.socketReady)))

        // Poll for the connecting → aiSpeaking transition event
        var connectingToAISpeakingEvent: CapturingTracker.Event?
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            connectingToAISpeakingEvent = tracker.events.first {
                $0.name == "speech_session_transition" &&
                $0.properties["from"] == "connecting" &&
                $0.properties["to"] == "aiSpeaking"
            }
            if connectingToAISpeakingEvent != nil {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(connectingToAISpeakingEvent != nil)

        // Verify phase actually moved
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 500_000_000)
    }

    // MARK: - Turn Counter Synchronization Tests

    @MainActor
    @Test func turnCounterSyncedWithMachineState() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // First turn
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        // Verify userTurnCount is 1
        #expect(store.state.speakingRoom.session.userTurnCount == 1)

        // Verify boundary was sent with correct turn ID
        let boundaries = await speechClient.getEndBoundaries()
        #expect(boundaries.last?.turnID == "turn-1")

        // Trigger AI response to return to waiting
        let frame = WSAudioFrame(sequence: 1, opusPayload: Data([0x01]))
        speechClient.emit(.audio(frame))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: nil, logID: nil)))
        try await waitForProcessingStage(store, stage: .evaluation, timeout: 1_000_000_000)

        // Second turn
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        // Verify userTurnCount is 2
        #expect(store.state.speakingRoom.session.userTurnCount == 2)

        // Verify second turn boundary
        let allEndBoundaries = await speechClient.getEndBoundaries()
        #expect(allEndBoundaries.last?.turnID == "turn-2")
    }
}

// MARK: - Reconnect Window Tests

@Suite("SpeechSessionMiddleware Reconnect Window")
struct SpeechSessionMiddlewareReconnectTests {

    /// Pins the truth about the "reconnect window": **it does not reconnect.**
    ///
    /// There is a three-second window, a `reconnectSucceeded` event, a
    /// "back into the session after connecting" transition and a
    /// `socketReady`-while-reconnecting handler — everything except something
    /// that dispatches the event or re-opens the socket. Every network loss
    /// therefore lands in text degrade, with no exception.
    ///
    /// That is not an oversight to be quietly patched: the gateway cannot
    /// resume a session at all. `auth` carries a one-time ticket and no session
    /// id, the gateway mints its own `session_id`, keeps per-session state in a
    /// struct discarded on disconnect, and has no session registry — so a
    /// reconnect would need a new frame, a lookup surviving restarts, and
    /// persisted live context. Backend evidence in `docs/55`.
    ///
    /// This test exists so the window cannot go back to looking alive. If
    /// someone implements reconnect, this fails and makes them update the
    /// comment rather than leaving a second lie in place.
    @MainActor
    @Test func networkLossDegradesAndNeverAttemptsAReconnect() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Network lost starts reconnect
        store.dispatch(.speakingRoom(.session(.networkLost)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.session.isReconnecting
        }
        #expect(store.state.speakingRoom.session.isReconnecting == true)

        // Wait out the window (3 seconds) plus slack.
        try await Task.sleep(for: .seconds(4))

        // After the window, the only outcome there is.
        #expect(store.state.speakingRoom.phase == .degradedText)
        #expect(store.state.speakingRoom.session.isReconnecting == false)

        // The pin: one connection attempt for the whole run — the one the user
        // started with. The window waited; it did not try.
        #expect(await speechClient.startSessionCallCount == 1)
    }

    @MainActor
    @Test func reconnectSucceededClearsReconnectFlag() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        // Network lost starts reconnect
        store.dispatch(.speakingRoom(.session(.networkLost)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.session.isReconnecting
        }

        // Reconnect succeeds before timeout
        speechClient.emit(.stateChanged(.connected))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            !store.state.speakingRoom.session.isReconnecting
        }

        #expect(store.state.speakingRoom.session.isReconnecting == false)
        #expect(store.state.speakingRoom.phase == .waitingUser)
    }
}

// MARK: - System Interrupt Tests

@Suite("SpeechSessionMiddleware System Interrupt")
struct SpeechSessionMiddlewareSystemInterruptTests {

    @MainActor
    @Test func audioEngineSystemInterruptSuspendsThenResumesToWaitingUser() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)

        audioEngine.emit(.interruptedBySystem)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.session.suspendedPhase == .aiSpeaking
        }
        #expect(store.state.speakingRoom.session.suspendedPhase == .aiSpeaking)
        #expect(store.state.speakingRoom.phase == .aiSpeaking)

        audioEngine.emit(.systemInterruptEnded)
        try await waitForPhase(store, phase: .waitingUser, timeout: 1_000_000_000)
        #expect(store.state.speakingRoom.session.suspendedPhase == nil)
    }
}

// MARK: - End Session Cleanup Tests

@Suite("SpeechSessionMiddleware End Session Cleanup")
struct SpeechSessionMiddlewareEndSessionTests {

    @MainActor
    @Test func endTapCancelsTransportAndAudioEngineTasks() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        // End session
        store.dispatch(.speakingRoom(.session(.endTap)))
        try await waitForPhase(store, phase: .ended, timeout: 1_000_000_000)

        // `.endSession` cleanup is fire-and-forget; poll instead of a fixed
        // sleep so parallel CI load cannot miss `speechClient.endSession()`.
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.endSessionCalled
        }

        #expect(await speechClient.endSessionCalled)
    }

    @MainActor
    @Test func failureCancelsTasksAndStopsAudioEngine() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware(startSessionError: StubError.simulatedFailure("Test error"))
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .failed, timeout: 1_000_000_000)

        // The .endSession effect is dispatched by the machine after entering .failed phase.
        // Wait for it to complete (stopCapture + endSession calls).
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.endSessionCalled
        }

        // Verify cleanup
        #expect(await audioEngine.stopCaptureCalled)
        #expect(await speechClient.endSessionCalled)
        // Verify failure reason is not nil
        #expect(store.state.speakingRoom.failureReason != nil)
        #expect(store.state.speakingRoom.phase == .failed)
    }
}

// MARK: - Non-Session Action Passthrough Tests

@Suite("SpeechSessionMiddleware Non-Session Action Tests")
struct SpeechSessionMiddlewarePassthroughTests {

    @MainActor
    @Test func nonSessionActionsPassThroughMiddleware() async throws {
        // Verify that non-.speakingRoom(.session(...)) actions go through unchanged
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }

        let store = AppStoreFactory.make(container: container)

        // These actions should not be intercepted by speechSessionMiddleware
        // Just verify they don't crash and are handled by the reducer
        store.dispatch(.speakingRoom(.bootstrapReady(true)))
        try await waitUntil(timeoutNanoseconds: 100_000_000) {
            store.state.speakingRoom.isBootstrapReady == true
        }
        #expect(store.state.speakingRoom.isBootstrapReady == true)

        store.dispatch(.speakingRoom(.badgeHit(badge: "test")))
        try await waitUntil(timeoutNanoseconds: 100_000_000) {
            store.state.speakingRoom.lastBadge == "test"
        }
        #expect(store.state.speakingRoom.lastBadge == "test")
        #expect(store.state.speakingRoom.badgeHits == 1)
    }
}

/// Tracker send/receive uses the same Container injected into middleware.
/// Production defaults to `Container.shared`; tests use a local `Container()`
/// because `tracker` is `.shared` (per-container), not a process singleton.
@Suite("I20 turn telemetry")
struct I20TurnTelemetryTests {
    @MainActor
    private func makeStore(
        audioEngine: StubAudioEngineForMiddleware,
        speechClient: StubSpeechSessionClientForMiddleware,
        tracker: CapturingTracker,
        decoder: MockTTSDecoder? = nil
    ) -> Store<AppState, AppAction> {
        let container = Container()
        container.reset()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { speechClient }
        container.tracker.register { tracker }
        if let decoder {
            container.ttsDecoder.register { decoder }
        }
        return AppStoreFactory.make(container: container)
    }

    @MainActor
    @Test func recordingTimeoutEmitsTurnTimeoutAndOutcomeViaSharedTracker() async throws {
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        let store = makeStore(audioEngine: audioEngine, speechClient: speechClient, tracker: tracker)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.recordingTimedOut)))
        try await waitForProcessingStage(store, stage: .aiAnswer, timeout: 1_000_000_000)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.getTurnAbortCalls().count == 1
        }

        let timeoutEvent = tracker.events.first { $0.name == "turn.timeout" }
        #expect(timeoutEvent?.properties["turn_id"] == "turn-1")
        #expect(timeoutEvent?.properties["elapsed_ms"] == "60000")
        let outcomeEvent = tracker.events.first { $0.name == "turn.outcome" }
        #expect(outcomeEvent?.properties["outcome"] == "timeout")
        #expect(tracker.events.filter { $0.name == "turn_timeout_fired" }.isEmpty)
        #expect(await speechClient.getTurnAbortCalls().first?.outcome == .timeout)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            tracker.events.contains {
                $0.name == "speech_session_transition"
                    && $0.properties["to_label"] == "waiting_for_ai_answer"
            }
        }
        #expect(
            tracker.events.contains {
                $0.name == "speech_session_transition"
                    && $0.properties["from_label"] == "vad_capture"
                    && $0.properties["to_label"] == "waiting_for_ai_answer"
            }
        )
    }

    @MainActor
    @Test func normalSpeechEndEmitsTurnOutcomeOkViaSharedTracker() async throws {
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        let store = makeStore(audioEngine: audioEngine, speechClient: speechClient, tracker: tracker)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            tracker.events.contains { $0.name == "turn.outcome" }
        }

        #expect(tracker.events.first { $0.name == "turn.outcome" }?.properties["outcome"] == "ok")
        #expect(tracker.events.filter { $0.name == "turn.timeout" }.isEmpty)
    }

    @MainActor
    @Test func aiTurnEndTraceJoinsTurnIDAndLogIDOnTracker() async throws {
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        let store = makeStore(audioEngine: audioEngine, speechClient: speechClient, tracker: tracker)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)
        audioEngine.emit(.speechEnded)
        try await waitForProcessingStage(store, stage: .asr, timeout: 1_000_000_000)

        speechClient.emit(
            .control(.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: "volc-abc123"))
        )
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            tracker.events.contains { $0.name == "timing_ai_turn_end" }
        }

        let endMark = tracker.events.first { $0.name == "timing_ai_turn_end" }
        #expect(endMark?.properties["turn_id"] == "turn-1")
        #expect(endMark?.properties["log_id"] == "volc-abc123")
        #expect(endMark?.properties["outcome"] == "ok")

        let duration = tracker.events.first { $0.name == "timing_turn_duration" }
        #expect(duration?.properties["turn_id"] == "turn-1")
        #expect(duration?.properties["log_id"] == "volc-abc123")
    }

    @MainActor
    @Test func endTapFromRecordingEmitsUserAbandonedViaSharedTracker() async throws {
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        let store = makeStore(audioEngine: audioEngine, speechClient: speechClient, tracker: tracker)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.endTap)))
        try await waitForPhase(store, phase: .ended, timeout: 1_000_000_000)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.getTurnAbortCalls().count == 1
        }

        #expect(
            tracker.events.contains {
                $0.name == "turn.outcome" && $0.properties["outcome"] == "user_abandoned"
            }
        )
        #expect(tracker.events.filter { $0.name == "turn.timeout" }.isEmpty)
        #expect(await speechClient.getTurnAbortCalls().first?.outcome == .userAbandoned)
    }

    @MainActor
    @Test func failedFromRecordingEmitsErrorViaSharedTracker() async throws {
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let tracker = CapturingTracker()
        let store = makeStore(audioEngine: audioEngine, speechClient: speechClient, tracker: tracker)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)
        store.dispatch(.speakingRoom(.session(.socketReady)))
        try await waitForPhase(store, phase: .aiSpeaking, timeout: 1_000_000_000)
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.failed("network"))))
        try await waitForPhase(store, phase: .failed, timeout: 1_000_000_000)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.getTurnAbortCalls().count == 1
        }

        #expect(
            tracker.events.contains {
                $0.name == "turn.outcome" && $0.properties["outcome"] == "error"
            }
        )
        #expect(tracker.events.filter { $0.name == "turn.timeout" }.isEmpty)
        #expect(await speechClient.getTurnAbortCalls().first?.outcome == .error)
    }

    @MainActor
    @Test func ttsStreamEmitsStartFirstAudioAndEndViaSharedTracker() async throws {
        let audioEngine = StubAudioEngineForMiddleware()
        let speechClient = StubSpeechSessionClientForMiddleware()
        let decoder = MockTTSDecoder()
        let tracker = CapturingTracker()
        let store = makeStore(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            decoder: decoder
        )

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        try await waitForPhase(store, phase: .connecting, timeout: 1_000_000_000)

        speechClient.emit(
            .control(
                .aiTTSStart(
                    turnID: "turn-9",
                    voiceID: "mock_voice_01",
                    sampleRate: 24_000,
                    codec: "opus"
                )
            )
        )
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            decoder.snapshotPrepares().count == 1
        }
        speechClient.emit(.audio(WSAudioFrame(sequence: 0, opusPayload: Data([0x0A, 0x0B]))))
        speechClient.emit(.audio(WSAudioFrame(sequence: 1, opusPayload: Data([0x0C]))))
        speechClient.emit(
            .control(.aiTTSEnd(turnID: "turn-9", completionStatus: "ok", durationMs: 40))
        )
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            tracker.events.contains { $0.name == "tts_end" }
        }

        let start = tracker.events.first { $0.name == "tts_start" }
        #expect(start?.properties["turn_id"] == "turn-9")
        #expect(start?.properties["voice_id"] == "mock_voice_01")
        #expect(start?.properties["codec"] == "opus")
        let firstAudio = tracker.events.first { $0.name == "tts_first_audio" }
        #expect(firstAudio?.properties["turn_id"] == "turn-9")
        #expect(firstAudio?.properties["sequence"] == "0")
        #expect(tracker.events.filter { $0.name == "tts_first_audio" }.count == 1)
        let end = tracker.events.first { $0.name == "tts_end" }
        #expect(end?.properties["turn_id"] == "turn-9")
        #expect(end?.properties["completion_status"] == "ok")
        #expect(end?.properties["audio_frames"] == "2")
        #expect(decoder.snapshotFeeds().map(\.seq) == [0, 1])
    }
}

@Suite("SpeechSessionMiddleware Engine Voice Processing")
struct SpeechSessionMiddlewareVoiceProcessingTests {

    /// The flag is the whole reason the engine-level switch is switchable: T4
    /// compares two builds that differ only in whether `voiceProcessing` is in
    /// `firstWave`. If the middleware stopped passing it through, both builds
    /// would run with the unit off and the comparison would silently become
    /// "off vs off" — the A/B would look like a clean result and mean nothing.
    @MainActor
    @Test func sessionStartPassesTheVoiceProcessingFlagToTheEngine() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { StubSpeechSessionClientForMiddleware() }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.featureFlags(.setLocalOverride(flag: .voiceProcessing, isEnabled: true)))
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))

        await expectTheEngineWasTold(audioEngine)
        #expect(await audioEngine.voiceProcessingValues == [true])
    }

    /// The shipped default. Pinned separately from the case above because
    /// "we never told the engine anything" and "we told it off" are different
    /// facts to the engine, and only the second one is deliberate.
    @MainActor
    @Test func sessionStartTellsTheEngineVoiceProcessingIsOffByDefault() async throws {
        let container = Container()
        container.reset()
        let audioEngine = StubAudioEngineForMiddleware()
        container.audioEngine.register { audioEngine }
        container.speechSessionClient.register { StubSpeechSessionClientForMiddleware() }

        let store = AppStoreFactory.make(container: container)
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))

        await expectTheEngineWasTold(audioEngine)
        #expect(await audioEngine.voiceProcessingValues == [false])
    }

    /// Waits for the middleware to hand the engine a value at all, and says
    /// why it might never have.
    ///
    /// A bare `waitUntil` would surface this as `TimeoutError`, which says
    /// nothing about the cause. The cause is specific and has already happened
    /// once: `setVoiceProcessingEnabled` was declared only in the
    /// `AudioEngineProtocol` extension, and an extension-only method is
    /// dispatched **statically** through `any AudioEngineProtocol` — so the
    /// default no-op ran, the real engine was never told, and every unit test
    /// that exercised `LiveAudioEngine` directly still passed.
    @MainActor
    private func expectTheEngineWasTold(_ audioEngine: StubAudioEngineForMiddleware) async {
        do {
            try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
                await !audioEngine.voiceProcessingValues.isEmpty
            }
        } catch {
            Issue.record(
                """
                The engine was never told about voice processing. Check that \
                `setVoiceProcessingEnabled` is a requirement of \
                `AudioEngineProtocol`, not only a defaulted extension method — \
                extension-only methods are dispatched statically through the \
                existential and never reach the real engine.
                """
            )
        }
    }
}

// MARK: - Test Helpers

private enum StubError: Error {
    case simulatedFailure(String)
}

/// Stub audio engine for middleware integration tests
private final class StubAudioEngineForMiddleware: AudioEngineProtocol, @unchecked Sendable {
    private let stream: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation

    private let _stopCaptureCalled = AsyncValue(false)
    var stopCaptureCalled: Bool { get async { await _stopCaptureCalled.get() } }
    private let _interruptCalls = AsyncValue(0)
    var interruptCalls: Int { get async { await _interruptCalls.get() } }
    private let _reconfigureCalls = AsyncValue(0)
    var reconfigureCalls: Int { get async { await _reconfigureCalls.get() } }
    /// Every value `setVoiceProcessingEnabled` was handed, in order. Recorded
    /// rather than ignored because the default protocol implementation is a
    /// no-op — without this, a middleware that stopped passing the flag through
    /// would look exactly like one that passes `false`.
    private let _voiceProcessingValues = AsyncValue<[Bool]>([])
    var voiceProcessingValues: [Bool] { get async { await _voiceProcessingValues.get() } }

    init() {
        let pair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startCapture() async throws {}

    func setVoiceProcessingEnabled(_ enabled: Bool) async {
        await _voiceProcessingValues.update { $0 + [enabled] }
    }
    func stopCapture() async {
        await _stopCaptureCalled.set(true)
    }
    func play(frame: WSAudioFrame) async {}
    func interruptNow() async {
        await _interruptCalls.update { $0 + 1 }
    }
    func discardActiveSpeech() async {}
    func reconfigureForRouteChange() async {
        await _reconfigureCalls.update { $0 + 1 }
    }

    func beginManualSpeech() async {
        emit(.speechStarted)
    }

    func endManualSpeech() async {
        emit(.speechEnded)
    }

    func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }

    func emit(_ event: AudioEngineEvent) {
        continuation.yield(event)
    }
}

/// Stub speech client for middleware integration tests
private final class StubSpeechSessionClientForMiddleware: SpeechSessionClientProtocol, @unchecked Sendable {
    struct BoundaryCall: Sendable {
        let started: Bool
        let turnID: String?
        let text: String?
    }

    struct AbortCall: Sendable {
        let turnID: String
        let outcome: TurnOutcome
    }

    private let stream: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation

    private let startSessionError: Error?
    private let _endSessionCalled = AsyncValue(false)
    var endSessionCalled: Bool { get async { await _endSessionCalled.get() } }

    private let _closeTransportCalled = AsyncValue(false)
    var closeTransportCalled: Bool { get async { await _closeTransportCalled.get() } }

    private let _speechBoundaryCalls = AsyncValue<[BoundaryCall]>([])
    private let _turnAbortCalls = AsyncValue<[AbortCall]>([])
    private let _degradedTextMessageSent = AsyncValue(false)
    var degradedTextMessageSent: Bool { get async { await _degradedTextMessageSent.get() } }
    private let _sessionID = AsyncValue<String?>(nil)

    private var sendDegradedResult: Result<PostMessageResponse, Error> = .success(
        PostMessageResponse(sessionID: "s-1", reply: "", channel: "text", generator: "stub")
    )

    init(startSessionError: Error? = nil) {
        self.startSessionError = startSessionError
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func setSendDegradedTextMessageResult(_ result: Result<PostMessageResponse, Error>) {
        sendDegradedResult = result
    }

    /// How many times a session was established. `startSession()` is the only
    /// thing that opens a connection, so this counts connection attempts —
    /// which is how a test proves a reconnect was *not* attempted.
    private let _startSessionCallCount = AsyncValue(0)
    var startSessionCallCount: Int { get async { await _startSessionCallCount.get() } }

    func startSession() async throws {
        await _startSessionCallCount.update { $0 + 1 }
        if let error = startSessionError {
            throw error
        }
        await _sessionID.set("s-1")
    }

    func activeSessionID() async -> String? { await _sessionID.get() }

    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {
        let call = BoundaryCall(started: started, turnID: turnID, text: text)
        await _speechBoundaryCalls.update { calls in
            var newCalls = calls
            newCalls.append(call)
            return newCalls
        }
    }

    func sendTurnAbort(turnID: String, outcome: TurnOutcome) async throws {
        await _turnAbortCalls.update { calls in
            var newCalls = calls
            newCalls.append(AbortCall(turnID: turnID, outcome: outcome))
            return newCalls
        }
    }

    func sendAudioPCM(_ data: Data) async throws {}
    func submitTranscript(_ text: String) async {}

    /// Counted so a test can assert the reader is built once per store rather
    /// than once per session. The stream itself is a single process-lifetime
    /// sequence (as the real transport's is), so asking for it per session
    /// means a fresh iterator competing with the previous one for events.
    private(set) var transportEventsRequestCount = 0

    func transportEvents() -> AsyncStream<SocketTransportEvent> {
        transportEventsRequestCount += 1
        return stream
    }

    func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        ReviewPollResponse(sessionID: sessionID, status: .pending, review: nil)
    }

    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        await _degradedTextMessageSent.set(true)
        return try sendDegradedResult.get()
    }

    func endSession() async {
        await _endSessionCalled.set(true)
        continuation.finish()
    }

    func closeTransport() async {
        await _closeTransportCalled.set(true)
        continuation.finish()
    }

    func emit(_ event: SocketTransportEvent) {
        continuation.yield(event)
    }

    // Test helper methods
    func getBoundaryCallCount() async -> Int {
        await _speechBoundaryCalls.get().count
    }

    func getLastBoundaryCall() async -> BoundaryCall? {
        await _speechBoundaryCalls.get().last
    }

    func getEndBoundaries() async -> [BoundaryCall] {
        await _speechBoundaryCalls.get().filter { !$0.started }
    }

    func getTurnAbortCalls() async -> [AbortCall] {
        await _turnAbortCalls.get()
    }
}

/// Simple actor-isolated value wrapper for test state
private actor AsyncValue<T: Sendable> {
    private var stored: T

    init(_ initial: T) {
        self.stored = initial
    }

    func get() -> T {
        stored
    }

    func set(_ newValue: T) {
        stored = newValue
    }

    func update(_ fn: (T) -> T) {
        stored = fn(stored)
    }
}

// MARK: - Wait Helpers

@MainActor
private func waitForPhase(
    _ store: Store<AppState, AppAction>,
    phase: SpeechSessionPhase,
    timeout: UInt64
) async throws {
    try await waitUntil(timeoutNanoseconds: timeout) {
        store.state.speakingRoom.phase == phase
    }
}

/// Waits for a specific pipeline step, not just "somewhere in processing".
///
/// `.processing` is one phase covering ASR, LLM and review, so a phase-only
/// wait can no longer tell a test which step it is standing in — and would
/// return immediately at a hop that the test exists to observe. Waiting on the
/// stage keeps the original precision.
@MainActor
private func waitForProcessingStage(
    _ store: Store<AppState, AppAction>,
    stage: ProcessingStage,
    timeout: UInt64
) async throws {
    try await waitUntil(timeoutNanoseconds: timeout) {
        store.state.speakingRoom.phase == .processing
            && store.state.speakingRoom.processingStage == stage
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
            throw TimeoutError()
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

private struct TimeoutError: Error {}
