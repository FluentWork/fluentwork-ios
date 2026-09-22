import FactoryKit
import FluentWorkDiagnostics
import FluentWorkFeatureFlags
import FluentWorkNetworking
import Foundation
import os
import TGReduxKit

public enum SpeechSessionTaskID {
    public static let reconnectWindow: CancellationID = "speechSession.reconnectWindow"
    public static let transportEvents: CancellationID = "speechSession.transportEvents"
    public static let audioEngineEvents: CancellationID = "speechSession.audioEngineEvents"
    // B15: turn-level timeout — fires when the backend's 60s collectTurn window
    // expires without an ai.turn.end. iOS uses this as a client-side fallback so
    // we don't hang indefinitely if the backend fails to surface the outcome.
    public static let turnTimeout: CancellationID = "speechSession.turnTimeout"
    // I20 T-I20-1: 60s cap while still recording. Distinct from `turnTimeout`.
    public static let recordingAbortTimeout: CancellationID = "speechSession.recordingAbortTimeout"
    public static let processingASRTimeout: CancellationID = "speechSession.processingASRTimeout"
    public static let processingLLMTimeout: CancellationID = "speechSession.processingLLMTimeout"
    public static let processingReviewTimeout: CancellationID = "speechSession.processingReviewTimeout"
    /// Wait for `feedback.badge` after `ai.turn.end`. Distinct from B15 70s.
    public static let evaluationTimeout: CancellationID = "speechSession.evaluationTimeout"
    /// Wait for `.socketReady` after entering `.connecting`.
    ///
    /// Every session starts in `.connecting` and nothing else bounded it: the
    /// ASR / LLM / review / evaluation / recording / reconnect / turn timers all
    /// begin later. A connect that never delivered `.socketReady` — the
    /// transport emitted nothing, the handshake stalled, a race ate the event —
    /// left the room showing 「连接中」 with no timeout, no error and no way
    /// forward but backing out of the screen.
    public static let connectTimeout: CancellationID = "speechSession.connectTimeout"
}

/// A one-shot latch. `take()` returns true exactly once.
internal final class OnceFlag: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: false)

    func take() -> Bool {
        storage.withLock { taken in
            guard !taken else { return false }
            taken = true
            return true
        }
    }
}

/// I20 T-I20-1: max time in `.recording` before `client.turn.abort`.
/// Not B15's 70s collectTurn fallback (`ProcessingTimeouts.totalCap`).
private let recordingAbortTimeout: Duration = .seconds(60)

/// Owns SpeechSessionMachine invocation + SideEffect interpretation.
///
/// Flow: `.speakingRoom(.session(event))` → pure reduce → `.applySession` + Effects.
public func speechSessionMiddleware(container: Container? = nil) -> Middleware<AppState, AppAction> {
    let resolvedContainer = container ?? Container.shared
    // Shared between the session event handler (writer, runs on @MainActor
    // via the middleware call) and the audio engine loop (reader, runs in
    // a detached `.task` block). Keeping the count here means the audio
    // loop never has to reach into the @MainActor store from a Sendable
    // closure.
    let turnCounter = TurnCountBox()
    let phaseBox = SessionPhaseBox()
    let timings = SpeechSessionTimingsRecorder(
        tracker: resolvedContainer.tracker(),
        clock: resolvedContainer.clock().now
    )
    // B15: turn-level timeout tracking — set when we enter .processing, cleared
    // when ai.turn.end arrives or the session ends. Lives here so both the
    // middleware dispatch path and the timeout tasks can access it.
    let turnTimeoutTracking = TurnTimeoutTracking()
    let speechCaptureGate = SpeechCaptureGate()
    let evaluationArrival = EvaluationArrivalBox()
    // 下行音频的唯一入口。它的 sink 就是引擎本身：`playbackRetired` 守卫住在
    // `play(pcm:)` 上，换一个对象去播会静默绕过它。（barge-in 的丢弃只剩传输层
    // 一处，引擎侧那道按序列号的水印已删除。）
    let ttsCoordinator = TTSPlaybackCoordinator(
        decoder: resolvedContainer.audioFrameDecoder(),
        sink: resolvedContainer.audioEngine()
    )
    let ttsTrace = TTSStreamTrace()
    // One reader per middleware instance (= per store), for its whole life.
    // Per instance rather than global so a test that builds its own store gets
    // its own pump instead of silently sharing one.
    // The two readers, started once per middleware instance (= per store) and
    // kept for its whole life. Per instance rather than global so a test that
    // builds its own store gets its own pumps instead of silently sharing one.
    let eventPumpsStarted = OnceFlag()

    return { store, action, next in
        if case .speakingRoom(.manualSpeechBegin) = action {
            return .fireAndForget {
                await resolvedContainer.audioEngine().beginManualSpeech()
            }
        }
        if case .speakingRoom(.manualSpeechEnd) = action {
            return .fireAndForget {
                await resolvedContainer.audioEngine().endManualSpeech()
            }
        }

        // The connection's reader starts the first time a session is asked for,
        // and only then. Deliberately **not** tied to `.lifecycle(.appLaunched)`:
        // that would make "the transport is readable" depend on an unrelated
        // event being dispatched, and a path that forgot it would hang on
        // 「连接中」 with nothing to show for it — the exact failure this whole
        // change exists to remove. See `transportEventPump`.
        var pumpEffects: [Effect<AppAction>] = []
        if case .speakingRoom(.session(.sessionStartTap)) = action, eventPumpsStarted.take() {
            pumpEffects.append(
                transportEventPump(
                    container: resolvedContainer,
                    dispatch: { store.dispatch($0) },
                    timings: timings,
                    turnTimeoutTracking: turnTimeoutTracking,
                    evaluationArrival: evaluationArrival,
                    ttsCoordinator: ttsCoordinator,
                    ttsTrace: ttsTrace
                )
            )
            // Both pumps, together. They are the two readers of process-lifetime
            // streams, and leaving either one per-session reproduces the same
            // failure for its own stream: the transport's leaves the room on
            // 「连接中」, the engine's leaves 「开始说话」 doing nothing.
            pumpEffects.append(
                audioEventPump(
                    container: resolvedContainer,
                    dispatch: { store.dispatch($0) },
                    turnCounter: turnCounter,
                    phaseBox: phaseBox,
                    timings: timings,
                    speechCaptureGate: speechCaptureGate
                )
            )
        }

        guard case let .speakingRoom(.session(event)) = action else {
            return .merge([next(action)] + pumpEffects)
        }

        var session = store.state.speakingRoom.session
        let preEventCount = session.userTurnCount
        let previousPhase = session.phase
        // Captured alongside the phase because the sub-stage timers hand off on
        // the *pipeline* advancing, and after the merge that advance no longer
        // changes the phase.
        let previousStage = session.processingStage
        let effects = SpeechSessionMachine.reduce(&session, event: event)
        // Keep the audio loop's "current count" in sync. The audio loop
        // computes `turnID = "turn-\(count + 1)"` at speech-end time —
        // this is the same value the machine's reduce will use to do the
        // transition's count increment, so the two never drift.
        turnCounter.set(session.userTurnCount)
        phaseBox.set(session.phase)

        // B15: flag to start the turn timeout when we enter .processing from
        // .recording. Sub-stage timers are scheduled as `.task(id:)` so they
        // cancel independently of the transport loop.
        let enteredProcessing = previousPhase == .recording && session.phase == .processing
        let enteredRecording = previousPhase != .recording && session.phase == .recording
        if event == .sessionStartTap {
            evaluationArrival.reset()
        }
        if enteredRecording {
            evaluationArrival.reset()
        }

        let apply = next(.speakingRoom(.applySession(session)))
        let interpreted = effects.map {
            interpretSpeechSessionSideEffect(
                $0,
                container: resolvedContainer,
                dispatch: { store.dispatch($0) },
                pendingTurnID: pendingTurnID(for: event, currentCount: preEventCount),
                turnCounter: turnCounter,
                timings: timings,
                turnTimeoutTracking: turnTimeoutTracking,
                speechCaptureGate: speechCaptureGate,
                evaluationArrival: evaluationArrival,
                ttsCoordinator: ttsCoordinator,
                ttsTrace: ttsTrace,
                usesAutoVAD: store.state.featureFlags.isEnabled(.voiceVadAuto),
                voiceProcessingEnabled: store.state.featureFlags.isEnabled(.voiceProcessing),
                // Where this session continues from, most recent first.
                //
                // `lastSessionID` is the session that just ended *in this
                // room* — so a restart mid-visit continues from what the user
                // was actually just talking about, rather than from wherever
                // the visit originally started. Falling back to
                // `continueFromSessionID` covers the first session of a visit
                // that was opened from the list.
                continueFromSessionID: store.state.speakingRoom.lastSessionID
                    ?? store.state.speakingRoom.continueFromSessionID
            )
        }
        let timeoutEffects = processingTimeoutEffects(
            from: previousPhase,
            to: session.phase,
            fromStage: previousStage,
            toStage: session.processingStage,
            enteredProcessing: enteredProcessing,
            enteredRecording: enteredRecording,
            turnTimeoutTracking: turnTimeoutTracking,
            speechCaptureGate: speechCaptureGate,
            evaluationArrival: evaluationArrival,
            tracker: resolvedContainer.tracker(),
            timeouts: resolvedContainer.processingTimeouts()
        )
        return .merge([apply] + interpreted + timeoutEffects + pumpEffects)
    }
}

/// Computes the turnID the middleware should send to the backend for an
/// end-of-utterance boundary (`vadSpeechEnd` / `holdEnd`). Other events
/// return `nil`; the rule lives here so the wire format and the
/// `userTurnCount` increment in the machine stay in lockstep.
/// - Note: `internal` for unit testing - remove `internal` qualifier in production
///   if test coupling is a concern.
internal func pendingTurnID(
    for event: SpeechSessionEvent,
    currentCount: Int
) -> String? {
    switch event {
    case .vadSpeechEnd, .holdEnd:
        return "turn-\(currentCount + 1)"
    default:
        return nil
    }
}

/// Sendable wrapper for the running `userTurnCount` so the audio engine
/// loop (which runs in its own unstructured Task) can read the latest
/// value without crossing actor boundaries.
///
/// Sync API on purpose: the middleware uses it from inside a sync
/// `Middleware` closure (writes) while the audio loop reads it from a
/// `Sendable` `.task` block. Apple `OSAllocatedUnfairLock` (iOS 16+) is
/// the modern, allocation-safe replacement for `NSLock` here — same
/// correctness, less footgun, no Foundation `import NSLock` style code.
/// - Note: `internal` for unit testing - remove `internal` qualifier in production
///   if test coupling is a concern.
internal final class TurnCountBox: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<Int>(initialState: 0)

    func get() -> Int { storage.withLock { $0 } }
    func set(_ newValue: Int) { storage.withLock { $0 = newValue } }
}

/// Last applied session phase, readable from the audio pump.
///
/// `speechStarted` is handled in the pump *before* it dispatches
/// `vadSpeechStart`. Barge-in from `.aiSpeaking` has to send `interrupt`
/// before `user.speech.start` (2026-09-12); the pump can only know that if
/// it can see the phase the machine is already in.
internal final class SessionPhaseBox: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<SpeechSessionPhase>(initialState: .idle)

    func get() -> SpeechSessionPhase { storage.withLock { $0 } }
    func set(_ newValue: SpeechSessionPhase) { storage.withLock { $0 = newValue } }
}

/// Tracks whether the current user utterance is still open on the wire.
///
/// I20 T-I20-1: after a recording abort the trailing VAD `speechEnded` is
/// ignored so we never send `user.speech.end` for an aborted turn — callers
/// check `isOpen` before dispatching.
///
/// PCM egress is bounded by the same flag. The microphone tap runs from
/// `startCapture()` until the session ends, so "forward everything that was
/// captured" leaks audio the user never opened a turn for. The gateway
/// commits its provider buffer on `user.speech.end`, so that leaked audio
/// lands in the *next* turn's transcript.
///
/// **The gate counts what it decides.** It used to be silent, and it was the
/// last completely invisible stage on the uplink — the engine reports every
/// format-level drop, while a chunk refused here left no counter, no event and
/// no timing mark anywhere. That matters because "the gate was shut while the
/// user was talking" is indistinguishable, from the wire, from "the microphone
/// produced nothing": both are a turn with zero uplink bytes. The number that
/// separates them is `forwarded`, and it is now recorded per utterance
/// (`audio_uplink_turn`).
internal final class SpeechCaptureGate: @unchecked Sendable {
    /// What the gate did during one utterance.
    ///
    /// `droppedOutside` is context, not a fault: most of a session is dropped by
    /// design (inter-turn gaps, the whole time the AI is speaking), so a bare
    /// drop count cannot be read as a problem. `forwarded` is the assertion —
    /// a user who spoke for two seconds and produced `forwarded: 0` is the
    /// `102_` silence, and it will now say so on the same turn it happened.
    struct TurnCounts: Equatable, Sendable {
        var forwarded: Int
        var droppedOutside: Int
    }

    private struct State {
        var open = false
        var forwarded = 0
        var droppedOutside = 0
    }

    private let storage = OSAllocatedUnfairLock<State>(initialState: State())

    func beginSpeech() {
        // Per-utterance, so `forwarded` cannot carry a previous turn's audio
        // into this one's reading — the count has to be about *this* turn to
        // answer "did the user's words reach the wire".
        storage.withLock {
            $0.open = true
            $0.forwarded = 0
        }
    }

    /// Normal turn end (`vadSpeechEnd` / `endManualSpeech`).
    @discardableResult
    func endSpeech() -> TurnCounts {
        storage.withLock {
            $0.open = false
            return TurnCounts(forwarded: $0.forwarded, droppedOutside: $0.droppedOutside)
        }
    }

    /// I20 recording abort. Identical wire effect to `endSpeech`; kept as a
    /// separate entry point because the call site also relies on the closed
    /// gate to swallow the trailing `speechEnded`.
    @discardableResult
    func abort() -> TurnCounts {
        storage.withLock {
            $0.open = false
            return TurnCounts(forwarded: $0.forwarded, droppedOutside: $0.droppedOutside)
        }
    }

    var isOpen: Bool {
        storage.withLock { $0.open }
    }

    /// Decide *and* count in one lock acquisition — the only PCM egress path.
    ///
    /// Split into "ask, then record" it would need two acquisitions, and a close
    /// landing between them would count a chunk that never left (or forward one
    /// after the turn ended, which is the transcript-pollution defect the gate
    /// exists to prevent).
    ///
    /// - Returns: `true` if this chunk may go on the wire.
    func takeForwardDecision() -> Bool {
        storage.withLock {
            if $0.open {
                $0.forwarded += 1
                return true
            }
            $0.droppedOutside += 1
            return false
        }
    }
}

/// Remembers a `feedback.badge` that arrived before `.waitingForEvaluation`.
/// Consume on enter so the wait does not hang when the badge beat `ai.turn.end`.
internal final class EvaluationArrivalBox: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: false)

    func mark() {
        storage.withLock { $0 = true }
    }

    /// Returns true and clears if a badge already landed for this turn.
    func consume() -> Bool {
        storage.withLock {
            let value = $0
            $0 = false
            return value
        }
    }

    func reset() {
        storage.withLock { $0 = false }
    }
}

/// B15: Tracks whether a turn-level timeout is currently armed.
/// Used to prevent double-firing when both the timeout task and ai.turn.end
/// race at the boundary. Cancelation is stored as a bool (not a Task) so the
/// transport loop can check it without awaiting.
internal final class TurnTimeoutTracking: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Returns true if the timeout was successfully armed (no prior armed timeout).
    @discardableResult
    func arm() -> Bool {
        storage.withLock {
            if $0 { return false }
            $0 = true
            return true
        }
    }

    /// Disarms any armed timeout. Safe to call multiple times.
    func disarm() {
        storage.withLock { $0 = false }
    }

    var isArmed: Bool {
        storage.withLock { $0 }
    }
}

/// The transport's event pump. One per process, never cancelled.
///
/// `AsyncStream` is a single-consumer sequence and the transport's stream
/// lives as long as the transport (`socketTransport` is a `.singleton`), so a
/// per-session iterator leaves a dying consumer competing with the next one
/// for the same events — and the cancellation that ends a session can land on
/// the *next* session's consumer instead, which then exits without a trace.
/// A room stuck on 「连接中」 is exactly that shape: measured on device, the
/// consumer started and exited 159ms later while the socket was up and the
/// client was writing to it successfully.
///
/// The official guidance for `URLSessionWebSocketTask` is a long-lived receive
/// loop; the transport already implements that. This is the same shape one
/// layer up, so the reader outlives the sessions it reads for.
/// The audio engine's event pump. One per store, never cancelled — the same
/// shape as `transportEventPump`, and for the same reason: the engine's
/// `events` stream lives as long as the engine, so a per-session consumer
/// over it leaves a dying iterator competing with the next one, and a
/// session-end cancellation can kill the *next* session's consumer instead.
///
/// Measured on device, on the first session re-entered after `.endSession`:
/// tapping 「开始说话」 did nothing. `beginManualSpeech()` reached the engine
/// and it emitted `.speechStarted` — into a stream nobody was reading. The
/// machine stayed on `waitingUser`, so the tap looked like it had failed.
///
/// `pcmBuffer` / `isCapturingSpeech` are locals here and so now live as long
/// as the store. Safe because `.speechStarted` clears the buffer *before*
/// opening `speechCaptureGate`: nothing buffered in a previous session can
/// reach the wire.
private func audioEventPump(
    container: Container,
    dispatch: @escaping @MainActor (AppAction) -> Void,
    turnCounter: TurnCountBox,
    phaseBox: SessionPhaseBox,
    timings: SpeechSessionTimingsRecorder,
    speechCaptureGate: SpeechCaptureGate
) -> Effect<AppAction> {
    let audioEngine = container.audioEngine()
    let speechClient = container.speechSessionClient()
    let dispatchBox = MainActorActionBox(dispatch: dispatch)
    let tracker = container.tracker()

    return .task {
            // B13: Buffer PCM chunks during speech for client ASR transcription
            var pcmBuffer: [Data] = []
            var isCapturingSpeech = false
            
            for await event in audioEngine.events() {
                if Task.isCancelled { return nil }
    
                switch event {
                case .speechStarted:
                    do {
                        // Reset PCM buffer at the start of each turn
                        pcmBuffer.removeAll()
                        isCapturingSpeech = true
                        speechCaptureGate.beginSpeech()

                        // Barge-in from AI speech: interrupt the in-flight
                        // reply *before* opening the next speech window.
                        // Sending start first is what made gateway
                        // delivered_chars: 0 on 2026-09-12 — start resets
                        // the previous turn's interrupt accounting.
                        if phaseBox.get() == .aiSpeaking {
                            await speechClient.submitTranscript("__interrupt__")
                        }

                        // No turnID on start — backend uses the next
                        // user.speech.end's turnID as the dedupe scope.
                        try await speechClient.sendSpeechBoundary(
                            started: true,
                            turnID: nil,
                            text: nil
                        )
                        timings.mark(event: "vad_speech_start")
                        await dispatchBox.dispatch(.speakingRoom(.session(.vadSpeechStart)))
                    } catch {
                        await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                        return nil
                    }
    
                case .speechEnded:
                    do {
                        isCapturingSpeech = false
                        // I20: abort already closed the utterance. Do not send
                        // user.speech.end — that would start collectTurn.
                        guard speechCaptureGate.isOpen else {
                            pcmBuffer.removeAll()
                            continue
                        }
                        let uplink = speechCaptureGate.endSpeech()
                        // Read together with the boundary it belongs to: a
                        // `speech_end` with `forwarded: 0` after a multi-second
                        // utterance is the `102_` silence stated as a number,
                        // and it is the one shape that cannot be diagnosed from
                        // either side alone — the client sent nothing, and the
                        // gateway correctly heard nothing.
                        timings.mark(
                            event: "audio_uplink_turn",
                            properties: [
                                "forwarded": String(uplink.forwarded),
                                "dropped_outside": String(uplink.droppedOutside),
                            ]
                        )
    
                        // B14 change: Server-side ASR (Volcengine Duplex relay) now provides
                        // the authoritative transcript via WSS `client.asr.transcription` frame.
                        // We no longer run local Apple Speech ASR here.
                        // We still signal turn-end so the backend can track the turn boundary.
                        // The backend will use its own Doubao transcript for badge detection.
                        let turnID = "turn-\(turnCounter.get() + 1)"
    
                        try await speechClient.sendSpeechBoundary(
                            started: false,
                            turnID: turnID,
                            text: nil
                        )
                        timings.markTurnStarted(turnID)
                        tracker.track(
                            event: "speech_turn_ended",
                            properties: [
                                "turn_id": turnID,
                                "source": "ios",
                                "stage": "turn_boundary",
                            ]
                        )
                        let sessionID = await container.speechSessionClient().activeSessionID()
                        emitTurnOutcome(
                            container: container,
                            sessionID: sessionID,
                            turnID: turnID,
                            outcome: .ok
                        )
                        await dispatchBox.dispatch(.speakingRoom(.session(.vadSpeechEnd(turnID: turnID))))
                        await dispatchBox.dispatch(.speakingRoom(.userTurnStarted(turnID: turnID)))
                        
                        // Clear buffer after use
                        pcmBuffer.removeAll()
                    } catch {
                        await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                        return nil
                    }
    
                case let .pcmChunk(data):
                    do {
                        // B13: Buffer PCM during speech capture for client ASR
                        if isCapturingSpeech {
                            pcmBuffer.append(data)
                        }
                        // The gate counts this decision, so a chunk refused here
                        // is no longer invisible. It is the normal path for most
                        // of a session; the count is what makes "shut the whole
                        // time" readable.
                        guard speechCaptureGate.takeForwardDecision() else { continue }
    
                        try await speechClient.sendAudioPCM(data)
                    } catch {
                        await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                        return nil
                    }
    
                case .interruptedBySystem:
                    await dispatchBox.dispatch(.speakingRoom(.session(.interruptedBySystem)))
    
                case let .captureKick(started, detail):
                    // The render-cycle kick's outcome. Informational, and the
                    // one diagnostic that makes the device run readable: with
                    // `.connecting` waiting on the microphone, "kicked but never
                    // delivered" and "never kicked" fail identically at the
                    // watchdog and are different bugs.
                    timings.mark(
                        event: "audio_capture_kick",
                        properties: [
                            "started": started ? "true" : "false",
                            "detail": detail,
                        ]
                    )

                case let .captureInterruptionLifted(droppedBuffers):
                    // Not a failure and no dispatch — the session continues
                    // exactly as before. Recorded because the guard that ate
                    // these buffers was invisible, and an interruption is the
                    // one event that can explain a gap in the uplink without
                    // anything being broken.
                    timings.mark(
                        event: "audio_capture_interruption_lifted",
                        properties: ["dropped_buffers": String(droppedBuffers)]
                    )

                case .systemInterruptEnded:
                    await dispatchBox.dispatch(.speakingRoom(.session(.systemInterruptEnded)))
    
                case let .routeChanged(reason):
                    timings.mark(event: "audio_route_changed", properties: ["reason": reason])
                    await audioEngine.reconfigureForRouteChange()

                case let .speechEndpointed(reason, windowMs, trailingSilenceMs):
                    // The distribution that decides the endpointing hold.
                    //
                    // `reason` separates the two ways a turn ends: the user
                    // pressed 说完了, or the room's silence hold decided. Only
                    // the second can cut someone off mid-sentence, and a
                    // `trailingSilenceMs` that sits right on the hold says the
                    // hold is what closed the turn. Without this the value can
                    // only be argued about, never set.
                    // Plain `mark`, not the turn-anchored one: this fires
                    // *before* the turn starts (the engine emits it ahead of
                    // `.speechEnded`, which is what calls `markTurnStarted`),
                    // so an anchor here would measure from the previous turn.
                    // The two numbers are self-contained anyway.
                    timings.mark(
                        event: "speech_endpointed",
                        properties: [
                            "reason": reason,
                            "window_ms": windowMs.map(String.init) ?? "unknown",
                            "trailing_silence_ms": trailingSilenceMs.map(String.init) ?? "unknown",
                        ]
                    )

                case let .voiceProcessing(detail):
                    // Not a dispatch and not a failure: the session runs either
                    // way. It is recorded because echo cancellation can only be
                    // judged on a device, and a device run cannot be read
                    // without knowing whether the switch was even on.
                    timings.mark(event: "audio_voice_processing", properties: ["detail": detail])

                case let .captureDropped(reason):
                    // Also informational — and also not a failure, since a graph
                    // that drops every buffer runs perfectly. It is recorded
                    // because this is the uplink's last silent gate: without it
                    // the client sends nothing, the gateway reports a turn it
                    // never heard, and neither side can say why. Emitted once per
                    // capture session by the engine.
                    timings.mark(event: "audio_capture_dropped", properties: ["reason": reason])

                case let .captureArmed(wasRunning, startAttempted, startThrew, running):
                    // Proves the graph was armed, not merely that it reached the
                    // format read. The four flags describe the start transition:
                    // "not running" is either "skipped, believed up" or
                    // "started, did not throw, still not running" — different
                    // bugs with one symptom.
                    timings.mark(
                        event: "audio_capture_armed",
                        properties: [
                            "was_running": wasRunning ? "true" : "false",
                            "start_attempted": startAttempted ? "true" : "false",
                            "start_threw": startThrew ? "true" : "false",
                            "running": running ? "true" : "false",
                        ]
                    )

                case .captureFirstBuffer:
                    // The tap fired. Without this line, a session that armed
                    // cleanly and then sent nothing means the graph is installed
                    // but not delivering — which no format or converter
                    // diagnostic can see.
                    timings.mark(event: "audio_capture_first_buffer")
                    // And it is more than a diagnostic: this is the half of
                    // "ready" the socket cannot speak for. `.connecting` now
                    // waits on both, so this dispatch is what opens the room for
                    // talking. A session that never reaches here now fails on the
                    // `connectWait` watchdog with a message the user can act on,
                    // instead of transcribing silence.
                    await dispatchBox.dispatch(.speakingRoom(.session(.captureLive)))
    
                case let .failed(message):
                    timings.mark(event: "audio_engine_failed", properties: ["message": message])
                    await dispatchBox.dispatch(.speakingRoom(.session(.failed(message))))
                    return nil
                }
            }
            return nil
    }
}

/// 组装传输事件的路由表。
///
/// 每个 handler 就是原先 `transportEventPump` 里那个 case 的 body，逐字搬过来，
/// 包括注释——那些注释记的是**顺序为什么是这样**，而顺序正是这次重构唯一可能
/// 悄悄改坏的东西。
///
/// 三点必须守住的：
///
/// 1. **handler 体内不得派生任务**（`Task {}` / `async let` / `withTaskGroup`）。
///    `for await` 的逐事件串行性来自循环自己 `await`，一旦 detach 就没了，而且
///    没有任何测试会因此变红。
/// 2. **`.feedbackBadge` 必须先 `evaluationArrival.mark()`**。这一帧同时被
///    `SocketTransportEventMapper` 映过一次，按 mapper 的写法搬就会丢掉这个 mark；
///    丢了之后 `processingTimeoutEffects` 走 `scheduleEvaluationWaitTask`，
///    于是**每一轮都白等 `evaluationWait`（默认 20s）**，不报错、只是慢。
/// 3. **`.clientASRTranscription` 是两次 dispatch**，mapper 只产生一次。
/// 内部而非 private：见 `MainActorActionBox`。生产接线与测试走的是同一个工厂——
/// 一个只有在生产里跑的工厂，和一张只有测试才看的表，都是这次要避免的形状。
internal func makeTransportEventRouter(
    container: Container,
    dispatchBox: MainActorActionBox,
    timings: SpeechSessionTimingsRecorder,
    turnTimeoutTracking: TurnTimeoutTracking,
    evaluationArrival: EvaluationArrivalBox,
    ttsCoordinator: TTSPlaybackCoordinator,
    ttsTrace: TTSStreamTrace
) -> TransportEventRouter {
    let audioHandler = AnyAudioFrameHandler { frame in
        // 唯一入口：播 / 丢由协调器按轮次归属判定，这里只负责埋点。
        // 归属来自「当前活跃的 ai.tts.start」——二进制帧上没有 turn_id。
        //
        // **判定必须排在埋点与相位翻转之前。** 被丢弃的帧不是「AI 开始说话了」——
        // 它一声不响。先宣告再判定，一个被丢掉的帧就会把会话推进到 `.aiSpeaking`
        // （`SpeechSessionMachine.swift:191`）并污染 `first_response_ms`；而
        // `markTurnOnce` / `markFirstResponse` 每轮只报一次，真正的那一帧再也
        // 纠正不了。钉住这一条的是 `ProductionRoutingWiringTests` 的两条测试。
        switch await ttsCoordinator.onAudioFrame(frame) {
        case let .played(turnID):
            await dispatchBox.dispatch(.speakingRoom(.session(.aiFirstAudioChunk)))
            // 一轮的音频有几百帧，但「第一帧什么时候到」只有一个时刻：
            // 逐帧打点会把那条真的埋在自己的重复里（250 帧 = 250 行）。
            timings.markTurnOnce(
                "ai_first_chunk",
                turnID: nil,
                properties: [
                    "sequence": String(frame.sequence),
                    "payload_bytes": String(frame.payload.count),
                ]
            )
            // P1-5: audio is the other way a turn can answer first, and
            // for "did the AI start speaking sooner" it is the one that
            // matters — text streams earlier but is silent. The recorder
            // keeps whichever channel arrives first, so a reply that
            // leads with audio is not overwritten by the text delta
            // chasing it. No turn id on the wire here: binary frames
            // carry a sequence and nothing else, so this resolves to the
            // turn most recently started.
            timings.markFirstResponse(nil, source: "audio")
            let count = ttsTrace.recordAudio()
            if count == 1 {
                container.tracker().track(
                    event: "tts_first_audio",
                    properties: [
                        "turn_id": turnID,
                        "sequence": String(frame.sequence),
                        "payload_bytes": String(frame.payload.count),
                    ]
                )
            }
        case let .dropped(turnID, reason, errorDescription):
            // 丢弃必须留痕。无 ai.tts.start 时帧会被丢弃并记录。
            container.tracker().track(
                event: reason == .decodeFailed ? "tts_decoder_failed" : "tts_frame_dropped",
                properties: [
                    "phase": "feed",
                    "turn_id": turnID ?? "nil",
                    "sequence": String(frame.sequence),
                    "reason": reason.rawValue,
                    "error": errorDescription ?? "n/a",
                ]
            )
        }
    }

    var controlHandlers: [WSControlFrameType: ControlFrameHandler] = [:]

    // `ai.tts.start` 是轮次归属的开始。从这里到 `ai.tts.end` 之间
    // 到达的二进制帧都属于这一轮（契约 `meta 83_`）。
    controlHandlers[.aiTTSStart] = AnyControlFrameHandler { frame in
        guard case let .aiTTSStart(turnID, voiceID, sampleRate, codec) = frame else {
            return
        }
        await ttsCoordinator.onStart(turnID: turnID)
        ttsTrace.reset()
        container.tracker().track(
            event: "tts_start",
            properties: [
                "turn_id": turnID,
                "voice_id": voiceID,
                "sample_rate": String(sampleRate),
                "codec": codec,
            ]
        )
    }

    controlHandlers[.aiTTSEnd] = AnyControlFrameHandler { frame in
        guard case let .aiTTSEnd(turnID, completionStatus, durationMs) = frame else {
            return
        }
        await ttsCoordinator.onEnd(turnID: turnID)
        container.tracker().track(
            event: "tts_end",
            properties: [
                "turn_id": turnID,
                "completion_status": completionStatus,
                "duration_ms": durationMs.map(String.init) ?? "nil",
                "audio_frames": String(ttsTrace.audioFrameCount()),
            ]
        )
    }

    controlHandlers[.feedbackBadge] = AnyControlFrameHandler { frame in
        guard case let .feedbackBadge(badge, phraseBlockID, tier, turnID) = frame else {
            return
        }
        // WSS has no eval.frame. `feedback.badge` is the turn-level
        // signal that can leave `.waitingForEvaluation`. Session
        // review stays on REST (I16).
        //
        // 这一行也是"badge 早于 ai.turn.end 到达"时不必等满窗口的原因：
        // 见 `processingTimeoutEffects` 里对 `evaluationArrival.consume()` 的分支。
        evaluationArrival.mark()
        let displayTier = tier.map(BadgeFeedEntry.Tier.from(transport:))
        await dispatchBox.dispatch(
            .speakingRoom(.badgeHit(
                badge: badge,
                phraseBlockID: phraseBlockID,
                tier: displayTier,
                turnID: turnID
            ))
        )
        await dispatchBox.dispatch(
            .speakingRoom(.session(.evaluationReceived))
        )
    }

    controlHandlers[.aiTurnEnd] = AnyControlFrameHandler { frame in
        guard case let .aiTurnEnd(turnID, outcome, logID) = frame else {
            return
        }
        // B15-I3: capture the vendor log_id from the first ai.turn.end.
        // setLogID is idempotent (only the first call stores the value).
        timings.setLogID(logID)
        // B15: ai.turn.end arrived — cancel the turn timeout timer so it
        // doesn't fire and cause a duplicate session.end. Safe to call
        // even if the timer was never started.
        turnTimeoutTracking.disarm()
        // B15: when backend explicitly reports outcome=timeout, dispatch
        // the same .failed("turn_timeout") as the 70s client-side fallback.
        // This makes the explicit timeout path consistent with the implicit
        // 70s timer path — both end the session identically.
        if outcome == .timeout {
            await dispatchBox.dispatch(.speakingRoom(.session(.failed("turn_timeout"))))
        } else {
            await dispatchBox.dispatch(.speakingRoom(.session(.aiTurnEnd)))
            await dispatchBox.dispatch(.speakingRoom(.aiTurnFinalized(turnID: turnID)))
            if let turnID {
                timings.markTurnEnded(turnID, source: "ios", stage: "ai_turn_end")
            }
            // B15-I3: log_id is now included in all mark() calls automatically.
            timings.mark(
                event: "ai_turn_end",
                properties: [
                    "turn_id": turnID ?? "nil",
                    "outcome": outcome?.rawValue ?? "nil", // B15: log outcome
                    "log_id": logID ?? "nil", // B15-I3: vendor trace log_id
                ]
            )
        }
    }

    controlHandlers[.aiTextDelta] = AnyControlFrameHandler { frame in
        guard case let .aiTextDelta(text, turnID, serverTsMs) = frame else {
            return
        }
        await dispatchBox.dispatch(
            .speakingRoom(.aiTurnTextDelta(text: text, turnID: turnID))
        )
        // P1-5: the first delta of a turn *is* the assistant starting
        // to answer, so it is where the wait ends. The recorder
        // reports once per turn — later deltas are the same answer
        // continuing, and counting them would turn "how long until
        // the AI spoke" into "how long until it finished".
        timings.markFirstResponse(turnID, source: "text", serverTsMs: serverTsMs)
    }

    controlHandlers[.clientASRTranscription] = AnyControlFrameHandler { frame in
        guard case let .clientASRTranscription(text, turnID) = frame else {
            return
        }
        // Display-layer transcript plus the ASR → LLM hop.
        // `.session(.serverASRReceived)` advances the ASR → LLM
        // stage; it still updates the
        // speaking-room transcript overlay.
        await dispatchBox.dispatch(
            .speakingRoom(.session(.serverASRReceived(text: text, turnID: turnID)))
        )
        await dispatchBox.dispatch(
            .speakingRoom(.serverASRReceived(text: text, turnID: turnID))
        )
        container.tracker().track(
            event: "server_asr_received_full",
            properties: [
                "turn_id": turnID ?? "nil",
                "text_bytes": String(text.utf8.count),
                "text": text,
            ]
        )
        // Anchored on the turn, not on the previous mark: the
        // question this line exists to answer is "how long after
        // the user stopped talking did their own words appear",
        // and the chain of marks in between is not something a
        // reader should have to sum.
        timings.markTurnAnchored(
            "server_asr_received",
            turnID: turnID,
            properties: [
                "text_bytes": String(text.utf8.count),
            ]
        )
        // NOTE: We intentionally do NOT call `sendSpeechBoundary` here.
        // The original iOS VAD already fired `user.speech.end` when the user
        // actually stopped speaking, which is what triggered the Volc commit
        // that produced this transcript. Re-emitting `user.speech.end` on
        // receipt of the relay frame would start a phantom second turn with
        // no audio, causing the gateway to wait 60s for nothing and the
        // client to surface "sockettransporterror error 3".
        // The backend already pulls the authoritative transcript out of
        // `ProviderOutbound.ServerASRText` for badge hit detection, so
        // nothing is lost by not pushing the text again.
    }

    let diagnosticHandler = AnyTransportEventHandler { event in
        guard case let .diagnostic(diagnostic) = event else {
            return
        }
        // 穷尽 switch：新增一类诊断会在这里编译失败，而不是被安静地忽略掉。
        switch diagnostic {
        case let .receiveLatency(frameType, sizeBytes, elapsedMs):
            container.tracker().track(
                event: "timing_socket_receive",
                properties: [
                    "frame_type": frameType,
                    "size_bytes": String(sizeBytes),
                    "elapsed_ms": String(format: "%.3f", elapsedMs),
                ]
            )

        // The barge-in watermark discarding inbound audio. Reported
        // at the start and end of each run, so `dropped` is the size
        // of the loss. A `sequence` at or below `watermark` on a
        // later turn is the signature of the gateway's numbering
        // going backwards — which is what makes this event worth
        // more than the silence it replaces.
        case let .clockOffsetEstimated(offset):
            // P1-5: a tighter gateway↔phone clock estimate. Handed to the
            // recorder rather than logged here — its only consumer is the
            // first-response mark, which needs it to split server time from
            // network time. Not tracked as its own event on purpose: it
            // repeats on every improvement, and the number worth reading is
            // the one attached to a turn, not the estimate on its own.
            timings.setClockOffset(offset)

        // A frame type this client does not know. The connection stays
        // up — that is the point — so without this line the only trace
        // of a server-side rollout would be a feature that appears to
        // do nothing. `type` is the datum: it names what we are behind
        // on, which is what says whether it matters.
        case let .unsupportedControlFrame(type, sizeBytes):
            container.tracker().track(
                event: "transport_control_frame_ignored",
                properties: [
                    "type": type,
                    "size_bytes": String(sizeBytes),
                ]
            )

        case let .audioFrameDropped(sequence, watermark, dropped):
            container.tracker().track(
                event: "transport_audio_dropped",
                properties: [
                    "sequence": String(sequence),
                    "watermark": String(watermark),
                    "dropped": String(dropped),
                ]
            )
        }
    }

    // 兜底：`.stateChanged`、`.failure`、以及 13 类没有专属 handler 的控制帧。
    //
    // 它们**本来就都落在这里**——这不是路由表漏了。其中只有 `.error` 会产生动作
    // （`.session(.failed)` → 完整 teardown），其余被 mapper 有意忽略。把这条写下来，
    // 是为了下一个人不必同时读两个 switch 才能确认某类帧是被忽略的。
    let fallbackHandler = AnyTransportEventHandler { event in
        guard let mapped = SocketTransportEventMapper.speakingRoomAction(for: event),
              let action = SpeakingRoomAction(mapped)
        else {
            // 原来是 `continue`：跳过这一条事件，继续读下一条。
            return
        }
        await dispatchBox.dispatch(.speakingRoom(action))
    }

    return TransportEventRouter(
        audioHandler: audioHandler,
        controlHandlers: controlHandlers,
        diagnosticHandler: diagnosticHandler,
        fallbackHandler: fallbackHandler
    )
}

private func transportEventPump(
    container: Container,
    dispatch: @escaping @MainActor (AppAction) -> Void,
    timings: SpeechSessionTimingsRecorder,
    turnTimeoutTracking: TurnTimeoutTracking,
    evaluationArrival: EvaluationArrivalBox,
    ttsCoordinator: TTSPlaybackCoordinator,
    ttsTrace: TTSStreamTrace
) -> Effect<AppAction> {
    let speechClient = container.speechSessionClient()
    let tracker = container.tracker()
    let dispatchBox = MainActorActionBox(dispatch: dispatch)
    // Built once per pump, next to the coordinator it routes to. "这类事件归谁"
    // 现在是一张静态表，而不是循环体里那个 237 行的 switch。
    let router = makeTransportEventRouter(
        container: container,
        dispatchBox: dispatchBox,
        timings: timings,
        turnTimeoutTracking: turnTimeoutTracking,
        evaluationArrival: evaluationArrival,
        ttsCoordinator: ttsCoordinator,
        ttsTrace: ttsTrace
    )

    // No id, and never cancelled: the pump is not a session resource.
    return .task {
            // A session that never leaves `.connecting` has exactly one
            // place to look: this loop. The transport emits `.connected`
            // locally the moment the auth frame is sent, so if the machine
            // stayed in `.connecting` the event was either never seen here
            // or dropped by the cancellation check below — and until now
            // neither left a trace.
            timings.mark(event: "transport_consumer_start")
            for await event in speechClient.transportEvents() {
                // Checked *after* `for await` has already taken the event, so
                // this branch discards a delivered event. That is the shape
                // of a lost `.connected`: a stale cancellation lands as the
                // session is starting, and the first event of the new
                // session — the only one that can leave `.connecting` — is
                // thrown away in silence. Record it instead.
                if Task.isCancelled {
                    timings.mark(
                        event: "transport_consumer_cancelled_with_event",
                        properties: ["dropped": describeTransportEvent(event)]
                    )
                    return nil
                }
    
                // The one event that can leave `.connecting`. Marked
                // separately from everything else because a room stuck on
                // 「连接中」 has exactly two explanations — the consumer was
                // not running when this was emitted, or it was running and
                // the event went somewhere else — and this line is what
                // tells them apart.
                if case .stateChanged(.connected) = event {
                    timings.mark(event: "transport_consumer_saw_connected")
                }
    
                // B14 debug: log all incoming transport control events to diagnose
                // missing feedback.badge frames. Remove after root cause is confirmed.
                //
                // 帧类型的标签现在取自 `WSControlFrame.wireType`（与线上 discriminator
                // 同一批字符串），不再手写第二份。两处措辞因此与旧日志不同：`auth` /
                // `handshake` 不再合并成 `<auth/handshake>`，`ai.turn.end` 之外的帧
                // 是否带 outcome 后缀不一致——这是 DEBUG 日志，没有测试钉过它。
                #if DEBUG
                if case let .control(frame) = event {
                    let typeTag: String
                    if case let .aiTurnEnd(_, outcome, _) = frame {
                        // outcome 是排查 ai.turn.end 时唯一要看的东西，保留后缀。
                        typeTag = "ai.turn.end" + (outcome.map { "(\($0.rawValue))" } ?? "")
                    } else {
                        typeTag = frame.wireType.rawValue
                    }
                    tracker.track(event: "transport_rx", properties: [
                        "frame_type": typeTag,
                        "badge_count": {
                            if case let .feedbackBadge(b, _, t, _) = frame {
                                return "badge=\(b) tier=\(t?.rawValue ?? "nil")"
                            }
                            return "n/a"
                        }(),
                    ])
                }
                #endif
    
                // 路由。这一条事件归谁，由 `makeTransportEventRouter` 的那张静态表
                // 决定；循环体只剩「读进来 → 判断该不该丢 → 记一笔 → 交出去」。
                //
                // 放在循环里而不是循环外，是因为它必须**逐事件串行**：循环体在每次
                // `await` 上挂起，下一条事件才会被取走。handler 体内一旦派生任务，
                // 这个保证就没了——而那不会让任何测试变红。
                await router.route(event: event)
            }
            // The loop exits for two very different reasons and this mark
            // has to say which. `for await` on a cancelled task returns nil
            // and ends the loop *normally* — it does not re-enter the body,
            // so the check inside cannot catch it. Reading `isCancelled`
            // here is what separates "cancelled" from "the transport's
            // stream is finished and can never yield again": the first is a
            // stale cancellation, the second means the transport object is
            // gone, and they need opposite fixes. Anything else is a guess.
            timings.mark(
                event: "transport_consumer_exit",
                properties: ["cancelled": Task.isCancelled ? "true" : "false"]
            )
            return nil
    }
}

private func interpretSpeechSessionSideEffect(
    _ effect: SpeechSessionSideEffect,
    container: Container,
    dispatch: @escaping @MainActor (AppAction) -> Void,
    pendingTurnID: String?,
    turnCounter: TurnCountBox,
    timings: SpeechSessionTimingsRecorder,
    turnTimeoutTracking: TurnTimeoutTracking? = nil,
    speechCaptureGate: SpeechCaptureGate,
    evaluationArrival: EvaluationArrivalBox,
    ttsCoordinator: TTSPlaybackCoordinator,
    ttsTrace: TTSStreamTrace,
    usesAutoVAD: Bool = false,
    voiceProcessingEnabled: Bool = false,
    continueFromSessionID: String? = nil
) -> Effect<AppAction> {
    let audioEngine = container.audioEngine()
    let speechClient = container.speechSessionClient()
    let tracker = container.tracker()
    let dispatchBox = MainActorActionBox(dispatch: dispatch)

    // Mark session-anchor events on the recorder so the iOS log carries the
    // wall-clock deltas next to the existing reducer transitions. The marks
    // here are coarse-grained (session lifecycle) — finer-grained
    // transport timing lives in `URLSessionSocketTransport.logReceiveLatency`.
    switch effect {
    case .createSession:
        timings.reset()
        timings.mark(event: "session_create", properties: ["stage": "orchestration"])
    case .sendInterrupt:
        timings.mark(event: "session_interrupt")
    case let .sendTurnAbort(turnID, outcome):
        timings.mark(event: "recording_turn_abort", properties: ["stage": "turn_boundary"])
        // Emit I20 tracker events on the middleware thread so they are not lost
        // if a later `.endSession` cancels the abort fire-and-forget.
        if outcome == .timeout {
            emitRecordingTurnTimeout(container: container, sessionID: nil, turnID: turnID)
        }
        emitTurnOutcome(container: container, sessionID: nil, turnID: turnID, outcome: outcome)
    case .stopPlayback:
        timings.mark(event: "playback_stop")
    case .pausePlayback:
        timings.mark(event: "playback_pause")
    case .resumePlayback:
        timings.mark(event: "playback_resume")
    case .startReconnectWindow:
        timings.mark(event: "reconnect_window_start")
    case .turnTimeoutExpired:
        timings.mark(event: "turn_timeout_expired", properties: ["stage": "turn_boundary"])
    case .endSession:
        timings.mark(event: "session_end")
    case .sendTextMessage:
        timings.mark(event: "degraded_text_send")
    case .forceClose:
        timings.mark(event: "session_force_close")
    case let .trackTransition(from, to, stage):
        // `trackTransition` fires alongside the reducer's `speech_session_transition`
        // event. We piggy-back the delta timing on the same transition so the
        // iOS log can match the backend's stage markers without a second
        // tracker stream.
        //
        // `stage` is what the backend log is keyed on, and after the processing
        // phases merged it is no longer recoverable from `to` alone.
        timings.mark(
            event: "phase_transition",
            properties: [
                "from": from.rawValue,
                "to": to.rawValue,
                "stage": stage?.stageTag ?? to.stageTag,
            ]
        )
    }

    switch effect {
    case .createSession:
        // B15 total-cap is armed by `processingTimeoutEffects` when we enter
        // .processing from recording — not from createSession.
        return .merge(
            .task {
                do {
                    try await speechClient.startSession(continueFromSessionID: continueFromSessionID)
                    await audioEngine.setSpeechBoundaryMode(usesAutoVAD ? .autoVAD : .tapToStart)
                    // Declared before `startCapture()`, not after: voice
                    // processing may only be toggled while the engine is
                    // stopped, and `startCapture()` is what starts it. The
                    // engine applies it while building the graph.
                    await audioEngine.setVoiceProcessingEnabled(voiceProcessingEnabled)
                    try await audioEngine.startCapture()
                } catch let error as AudioEnginePermissionError {
                    let message: String
                    switch error {
                    case .microphoneDenied:
                        message = "无法访问麦克风，请在系统设置中允许 FluentWork 使用麦克风。"
                    }
                    return .speakingRoom(.session(.failed(message)))
                } catch let error as AudioEngineError {
                    // Logged in full, then shown generically.
                    //
                    // `AudioEngineError` is not `LocalizedError`, so
                    // `localizedDescription` is the synthesized "The operation
                    // couldn't be completed. (FluentWorkCore.AudioEngineError
                    // error 0.)" — which means the format facts the new guards
                    // were written to carry reach nobody at all. Writing
                    // Chinese copy for them is a product decision; getting them
                    // into the log is not, and
                    // a device run that dies at a format guard is unreadable
                    // without them.
                    let detail: String
                    switch error {
                    case let .invalidFormat(message), let .audioSessionConflict(message):
                        detail = message
                    }
                    timings.mark(event: "audio_engine_failed", properties: ["detail": detail])
                    return .speakingRoom(.session(.failed(error.localizedDescription)))
                } catch {
                    return .speakingRoom(.session(.failed(error.localizedDescription)))
                }
                return nil
            }
        )

    case .sendInterrupt:
        return .fireAndForget {
            await speechClient.submitTranscript("__interrupt__")
        }

    case let .sendTurnAbort(turnID, outcome):
        return .fireAndForget {
            speechCaptureGate.abort()
            await audioEngine.discardActiveSpeech()
            do {
                try await speechClient.sendTurnAbort(turnID: turnID, outcome: outcome)
            } catch {
                await dispatchBox.dispatch(
                    .speakingRoom(.session(.failed(error.localizedDescription)))
                )
            }
        }

    case .stopPlayback:
        return .fireAndForget {
            let turnID = await ttsCoordinator.currentTurnID()
            // 协调器做两件事：把这一轮标记为作废（挡住还在链路上的帧），
            // 并让 sink 清空已经排进播放器的缓冲。第二条由它自己调 ——
            // sink 就是 `audioEngine`，这里再调一次是重复的。
            await ttsCoordinator.onInterrupt(turnID: turnID)
            container.tracker().track(
                event: "tts_interrupt",
                properties: ["turn_id": turnID ?? "nil"]
            )
        }

    case .pausePlayback:
        return .fireAndForget {
            await audioEngine.pausePlayback()
        }

    case .resumePlayback:
        return .fireAndForget {
            await audioEngine.resumePlayback()
        }

    // **A degrade timer, not a reconnect wait.**
    //
    // It sleeps and dispatches `.reconnectTimedOut`; it never re-opens the
    // socket. The name and the state machine around it (`reconnecting`,
    // `.reconnectSucceeded`, the `socketReady`-while-reconnecting branch) all
    // read as though a reconnect were in flight — it is not. Every network loss
    // reaches `degradedText`.
    //
    // The window is deliberately kept: it is the honest amount of time to give
    // a future reconnect attempt, and `networkLossDegradesAndNeverAttemptsAReconnect`
    // pins the current behaviour so implementing one is a deliberate act rather
    // than a silent drift. It cannot be implemented client-side alone.
    case .startReconnectWindow:
        return .task(id: SpeechSessionTaskID.reconnectWindow) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return nil }
            await dispatchBox.dispatch(.speakingRoom(.session(.reconnectTimedOut)))
            return nil
        }

    // B15: turn timeout fired — backend's 60s collectTurn window expired.
    // Dispatch a failed event so the machine transitions to .failed, which
    // then triggers endSession. disarm() is called in endSession too but
    // we disarm here for safety in case endSession is never reached.
    case .turnTimeoutExpired:
        turnTimeoutTracking?.disarm()
        return .task {
            await dispatchBox.dispatch(.speakingRoom(.session(.failed("turn_timeout"))))
            return nil
        }

    case .endSession:
        // B15: cancel all session-scoped tasks including the turn timeout.
        // disarm() is safe to call even if the timer was never started.
        turnTimeoutTracking?.disarm()
        return .merge(
            // Clear the turn attribution so a leftover `ai.tts.start` cannot claim
            // the next session's PCM if the host restarts immediately.
            .fireAndForget { await ttsCoordinator.reset() },
            // No `.cancel(id: transportEvents)`: the reader belongs to the
            // connection. Cancelling it here killed the *next* session's
            // consumer when the timing fell wrong, and the room sat on
            // 「连接中」 with nothing in the log. See `transportEventPump`.
            // No `.cancel(id: audioEngineEvents)`: that reader belongs to the
            // engine, not to this session. See `audioEventPump`.
            .cancel(id: SpeechSessionTaskID.recordingAbortTimeout),
            .cancel(id: SpeechSessionTaskID.evaluationTimeout),
            cancelProcessingTimeoutTasks(includeTotalCap: true),
            .fireAndForget {
                let sessionID = await speechClient.activeSessionID()
                await audioEngine.stopCapture()
                await speechClient.endSession()
                if let sessionID {
                    await dispatchBox.dispatch(.speakingRoom(.sessionIDCaptured(sessionID)))
                }
            }
        )

    case .forceClose:
        // Machine already moved to `.ended`. Do not dispatch `.endTap` — that
        // would double-end. Buy a background window, stop capture, send
        // `session.end`, then disconnect. Skip `end` when begin returns 0.
        turnTimeoutTracking?.disarm()
        let backgroundTasks = container.backgroundTaskPort()
        return .merge(
            .fireAndForget { await ttsCoordinator.reset() },
            // No `.cancel(id: transportEvents)`: the reader belongs to the
            // connection. Cancelling it here killed the *next* session's
            // consumer when the timing fell wrong, and the room sat on
            // 「连接中」 with nothing in the log. See `transportEventPump`.
            // No `.cancel(id: audioEngineEvents)`: that reader belongs to the
            // engine, not to this session. See `audioEventPump`.
            .cancel(id: SpeechSessionTaskID.recordingAbortTimeout),
            .cancel(id: SpeechSessionTaskID.evaluationTimeout),
            cancelProcessingTimeoutTasks(includeTotalCap: true),
            .fireAndForget {
                let taskID = await backgroundTasks.begin(
                    name: "fluentwork.forceClose",
                    expirationHandler: {}
                )
                let sessionID = await speechClient.activeSessionID()
                await audioEngine.stopCapture()
                await speechClient.endSession()
                await speechClient.closeTransport()
                if let sessionID {
                    await dispatchBox.dispatch(.speakingRoom(.sessionIDCaptured(sessionID)))
                }
                if taskID != 0 {
                    await backgroundTasks.end(taskID)
                }
            }
        )

    case .sendTextMessage:
        return .task {
            do {
                // Text body is owned by UI later; keep wiring with empty payload for now.
                _ = try await speechClient.sendDegradedTextMessage("")
                return nil
            } catch {
                return .speakingRoom(.session(.failed(error.localizedDescription)))
            }
        }

    case let .trackTransition(from, to, stage):
        return .fireAndForget {
            tracker.track(
                event: "speech_session_transition",
                properties: [
                    "from": from.rawValue,
                    "to": to.rawValue,
                    // `from_label` stays the *phase* label: it must not be
                    // back-filled with the stage, or a stage advance
                    // (`from == to == .processing`) would report the
                    // destination as its own origin. `to_label` resolves with
                    // the stage because that is the half that answers "where is
                    // it now" — and for the merged pipeline the phase alone
                    // cannot.
                    "from_label": from.label,
                    "to_label": stage?.stageTag ?? to.label,
                    "stage": stage?.stageTag ?? "",
                ]
            )
        }
    }
}

/// Arms / cancels processing sub-timers and the B15 70s total cap via `.task(id:)`.
/// Also arms the I20 60s recording abort (separate CancellationID, separate path).
private func processingTimeoutEffects(
    from previousPhase: SpeechSessionPhase,
    to newPhase: SpeechSessionPhase,
    fromStage previousStage: ProcessingStage?,
    toStage newStage: ProcessingStage?,
    enteredProcessing: Bool,
    enteredRecording: Bool,
    turnTimeoutTracking: TurnTimeoutTracking,
    speechCaptureGate: SpeechCaptureGate,
    evaluationArrival: EvaluationArrivalBox,
    tracker: TrackerClientProtocol,
    timeouts: ProcessingTimeouts
) -> [Effect<AppAction>] {
    var effects: [Effect<AppAction>] = []

    if enteredRecording {
        effects.append(scheduleRecordingAbortTask(captureGate: speechCaptureGate))
    }

    if previousPhase == .recording, newPhase != .recording {
        effects.append(.cancel(id: SpeechSessionTaskID.recordingAbortTimeout))
    }

    if enteredProcessing {
        turnTimeoutTracking.arm()
        effects.append(scheduleTurnTimeoutTask(tracking: turnTimeoutTracking, tracker: tracker, timeouts: timeouts))
        effects.append(scheduleProcessingTimeoutTask(stage: .asr, timeouts: timeouts, tracker: tracker))
    }

    // The sub-stage timers hand off on the pipeline advancing, which after the
    // merge is a stage change rather than a phase change. Keyed on the stage so
    // the handoff cannot be skipped by a phase that no longer moves.
    if previousStage == .asr, newStage == .llm {
        effects.append(.cancel(id: SpeechSessionTaskID.processingASRTimeout))
        effects.append(scheduleProcessingTimeoutTask(stage: .llm, timeouts: timeouts, tracker: tracker))
    }

    if previousStage == .llm, newStage == .review {
        effects.append(.cancel(id: SpeechSessionTaskID.processingLLMTimeout))
        effects.append(scheduleProcessingTimeoutTask(stage: .review, timeouts: timeouts, tracker: tracker))
    }

    if previousPhase.isProcessing, !newPhase.isProcessing {
        effects.append(cancelProcessingTimeoutTasks(includeTotalCap: false))
    }

    if newPhase == .waitingUser || newPhase == .ended || newPhase == .failed {
        turnTimeoutTracking.disarm()
        effects.append(cancelProcessingTimeoutTasks(includeTotalCap: true))
    }

    // Keyed on the stage: the evaluation wait is no longer a phase, so entering
    // and leaving it are stage changes inside `.processing`.
    if previousStage != .evaluation, newStage == .evaluation {
        if evaluationArrival.consume() {
            effects.append(.task {
                return .speakingRoom(.session(.evaluationReceived))
            })
        } else {
            effects.append(scheduleEvaluationWaitTask(timeouts: timeouts))
        }
    }

    if previousStage == .evaluation, newStage != .evaluation {
        effects.append(.cancel(id: SpeechSessionTaskID.evaluationTimeout))
    }

    if previousPhase != .connecting, newPhase == .connecting {
        effects.append(scheduleConnectWaitTask(timeouts: timeouts))
    }

    if previousPhase == .connecting, newPhase != .connecting {
        effects.append(.cancel(id: SpeechSessionTaskID.connectTimeout))
    }

    return effects
}

/// Bounds the very first phase of a session.
///
/// Nothing else did. A connect that never produced `.socketReady` left the room
/// on 「连接中」 indefinitely — no timeout, no error, and no way forward but
/// backing out of the screen. Failing is the honest outcome: the user gets a
/// retryable message instead of a screen that never moves.
/// Names a transport event for the tracker. Only the two that can strand
/// `.connecting` need names — everything else is already visible through the
/// events it produces downstream.
private func describeTransportEvent(_ event: SocketTransportEvent) -> String {
    switch event {
    case .stateChanged(.connected): return "stateChanged.connected"
    case .stateChanged(.connecting): return "stateChanged.connecting"
    case .stateChanged(.reconnecting): return "stateChanged.reconnecting"
    case .stateChanged(.disconnected): return "stateChanged.disconnected"
    case .stateChanged(.idle): return "stateChanged.idle"
    case .control: return "control"
    case .audio: return "audio"
    case .diagnostic: return "diagnostic"
    case .failure: return "failure"
    }
}

private func scheduleConnectWaitTask(timeouts: ProcessingTimeouts) -> Effect<AppAction> {
    .task(id: SpeechSessionTaskID.connectTimeout) {
        try? await Task.sleep(for: timeouts.connectWait)
        guard !Task.isCancelled else { return nil }
        return .speakingRoom(.session(.failed("连接超时，请重试")))
    }
}

/// Counts TTS binary frames between `ai.tts.start` and `ai.tts.end` so we can
/// trace a stream without logging every Opus packet.
/// - Note: `internal` for unit testing.
internal final class TTSStreamTrace: Sendable {
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    func reset() {
        frames.withLock { $0 = 0 }
    }

    func recordAudio() -> Int {
        frames.withLock {
            $0 += 1
            return $0
        }
    }

    func audioFrameCount() -> Int {
        frames.withLock { $0 }
    }
}

private func emitRecordingTurnTimeout(
    container: Container,
    sessionID: String?,
    turnID: String
) {
    container.tracker().track(
        event: "turn.timeout",
        properties: [
            "session_id": sessionID ?? "nil",
            "turn_id": turnID,
            "elapsed_ms": "60000",
        ]
    )
}

private func emitTurnOutcome(
    container: Container,
    sessionID: String?,
    turnID: String,
    outcome: TurnOutcome
) {
    container.tracker().track(
        event: "turn.outcome",
        properties: [
            "outcome": outcome.rawValue,
            "session_id": sessionID ?? "nil",
            "turn_id": turnID,
        ]
    )
}

private func scheduleRecordingAbortTask(captureGate: SpeechCaptureGate) -> Effect<AppAction> {
    .task(id: SpeechSessionTaskID.recordingAbortTimeout) {
        try? await Task.sleep(for: recordingAbortTimeout)
        guard !Task.isCancelled else { return nil }
        captureGate.abort()
        return .speakingRoom(.session(.recordingTimedOut))
    }
}

private func scheduleEvaluationWaitTask(timeouts: ProcessingTimeouts) -> Effect<AppAction> {
    .task(id: SpeechSessionTaskID.evaluationTimeout) {
        try? await Task.sleep(for: timeouts.evaluationWait)
        guard !Task.isCancelled else { return nil }
        return .speakingRoom(.session(.evaluationTimedOut))
    }
}

private func scheduleTurnTimeoutTask(
    tracking: TurnTimeoutTracking,
    tracker: TrackerClientProtocol,
    timeouts: ProcessingTimeouts
) -> Effect<AppAction> {
    let timeout = timeouts.totalCap
    return .task(id: SpeechSessionTaskID.turnTimeout) {
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return nil }
        guard tracking.isArmed else { return nil }
        tracker.track(
            event: "turn_timeout_fired",
            properties: ["timeout_sec": "\(timeout.components.seconds)"]
        )
        return .speakingRoom(.session(.failed("turn_timeout")))
    }
}

private func scheduleProcessingTimeoutTask(
    stage: ProcessingStage,
    timeouts: ProcessingTimeouts,
    tracker: TrackerClientProtocol
) -> Effect<AppAction> {
    let duration: Duration
    let cancellationID: CancellationID
    let trackEvent: String
    let stageName: String
    switch stage {
    case .asr:
        duration = timeouts.asr
        cancellationID = SpeechSessionTaskID.processingASRTimeout
        trackEvent = "processing_timeout_asr"
        stageName = "asr"
    case .llm:
        duration = timeouts.llm
        cancellationID = SpeechSessionTaskID.processingLLMTimeout
        trackEvent = "processing_timeout_llm"
        stageName = "llm"
    case .review:
        duration = timeouts.review
        cancellationID = SpeechSessionTaskID.processingReviewTimeout
        trackEvent = "processing_timeout_review"
        stageName = "review"
    case .evaluation, .aiAnswer:
        // The two wait stages have no pipeline budget. `.evaluation` is bounded
        // by its own `evaluationTimeout`, and `.aiAnswer` deliberately is not
        // bounded at all — the aborted turn's answer is still coming, and the
        // turn-level cap already covers the session. Returning inert rather
        // than inventing a budget: a budget nobody chose is how a timer ends up
        // owning user-visible behaviour (F19).
        return .merge([])
    }
    return .task(id: cancellationID) {
        try? await Task.sleep(for: duration)
        guard !Task.isCancelled else { return nil }
        // A budget overrun is diagnostic, not a verdict.
        //
        // These budgets are 15s / 45s / 30s while the gateway waits 60s for the
        // vendor, so ending the session here made the server's budget
        // unreachable: any turn where the vendor took longer than 15s died on
        // the client even though the server would have answered. Observed on a
        // physical device on 2026-09-11 — the gateway was still inside
        // collectTurn at its 60s window when the client had already given up at
        // 15.9s.
        //
        // The authoritative end of a turn is `ai.turn.end` from the gateway, or
        // the B15 total cap (`timeouts.totalCap`) when nothing arrives. Report
        // the overrun and leave the turn running.
        tracker.track(event: trackEvent, properties: ["stage": stageName])
        return nil
    }
}

private func cancelProcessingTimeoutTasks(includeTotalCap: Bool) -> Effect<AppAction> {
    var effects: [Effect<AppAction>] = [
        .cancel(id: SpeechSessionTaskID.processingASRTimeout),
        .cancel(id: SpeechSessionTaskID.processingLLMTimeout),
        .cancel(id: SpeechSessionTaskID.processingReviewTimeout),
        .cancel(id: SpeechSessionTaskID.connectTimeout),
    ]
    if includeTotalCap {
        effects.append(.cancel(id: SpeechSessionTaskID.turnTimeout))
    }
    return .merge(effects)
}

/// 内部而非 private：`makeTransportEventRouter` 需要它，而接线后的路由表由
/// `TransportRoutingEquivalenceTests` 用真实工厂驱动（@testable import）。
internal final class MainActorActionBox: @unchecked Sendable {
    private let dispatch: @MainActor (AppAction) -> Void

    init(dispatch: @escaping @MainActor (AppAction) -> Void) {
        self.dispatch = dispatch
    }

    func dispatch(_ action: AppAction) async {
        await dispatch(action)
    }
}
