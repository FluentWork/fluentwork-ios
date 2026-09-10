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

    @Test func speechCaptureGateDropsPCMAfterAbortUntilNextSpeech() {
        let gate = SpeechCaptureGate()
        #expect(gate.shouldForwardPCM)
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

    @Test func speechCaptureGateEndSpeechStillForwardsPCM() {
        let gate = SpeechCaptureGate()
        gate.beginSpeech()
        gate.endSpeech()
        #expect(!gate.isOpen)
        #expect(gate.shouldForwardPCM)
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
@Suite("SpeechSessionMiddleware B14 Integration")
struct SpeechSessionMiddlewareB14Tests {

    // MARK: - Server ASR Tests

    @MainActor
    @Test func serverASRDispatchesTranscriptUpdateViaReducer() async throws {
        // Note: serverASRReceived can be dispatched two ways:
        // 1. As .session(.serverASRReceived) - advances processingASR → processingLLM
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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

        let boundariesAfterVAD = await speechClient.getBoundaryCallCount()
        speechClient.emit(.control(.clientASRTranscription(text: "Transport transcript", turnID: "turn-1")))
        try await waitForPhase(store, phase: .processingLLM, timeout: 1_000_000_000)

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
        try await waitForPhase(store, phase: .waitingForAIAnswer, timeout: 1_000_000_000)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await speechClient.getTurnAbortCalls().count == 1
        }

        let aborts = await speechClient.getTurnAbortCalls()
        #expect(aborts.count == 1)
        #expect(aborts.first?.turnID == "turn-1")
        #expect(aborts.first?.outcome == .timeout)
        #expect(await speechClient.getEndBoundaries().isEmpty)
        #expect(await speechClient.endSessionCalled == false)
        #expect(store.state.speakingRoom.phase == .waitingForAIAnswer)
        #expect(store.state.speakingRoom.session.failureReason == nil)

        audioEngine.emit(.speechEnded)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speechClient.getEndBoundaries().isEmpty)
        #expect(store.state.speakingRoom.phase == .waitingForAIAnswer)

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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

        speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil)))
        try await waitForPhase(store, phase: .waitingForEvaluation, timeout: 1_000_000_000)

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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

        speechClient.emit(.control(.feedbackBadge(
            badge: "ship it",
            phraseBlockID: "block-2",
            tier: .highlight,
            turnID: "turn-1"
        )))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.lastBadge == "ship it"
        }
        #expect(store.state.speakingRoom.phase == .processingASR)

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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

        speechClient.emit(.control(.aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil)))
        try await waitForPhase(store, phase: .waitingForEvaluation, timeout: 1_000_000_000)

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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

        store.dispatch(.speakingRoom(.session(.networkLost)))
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            store.state.speakingRoom.session.isReconnecting
        }
        #expect(store.state.speakingRoom.phase == .processingASR)

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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)
        #expect(store.state.speakingRoom.phase == .processingASR)
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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

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
        try await waitForPhase(store, phase: .waitingForEvaluation, timeout: 1_000_000_000)

        // Second turn
        audioEngine.emit(.speechStarted)
        try await waitForPhase(store, phase: .recording, timeout: 1_000_000_000)

        audioEngine.emit(.speechEnded)
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

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

    @MainActor
    @Test func reconnectWindowTriggersAfterTimeout() async throws {
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

        // Wait for reconnect timeout (3 seconds)
        try await Task.sleep(for: .seconds(4))

        // After timeout, should enter degradedText
        #expect(store.state.speakingRoom.phase == .degradedText)
        #expect(store.state.speakingRoom.session.isReconnecting == false)
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
        try await waitForPhase(store, phase: .waitingForAIAnswer, timeout: 1_000_000_000)
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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)
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
        try await waitForPhase(store, phase: .processingASR, timeout: 1_000_000_000)

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

    init() {
        let pair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func startCapture() async throws {}
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

    func startSession() async throws {
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

    func transportEvents() -> AsyncStream<SocketTransportEvent> {
        stream
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
