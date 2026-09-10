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
    let timings = SpeechSessionTimingsRecorder(
        tracker: resolvedContainer.tracker(),
        clock: resolvedContainer.clock().now
    )
    // B15: turn-level timeout tracking — set when we enter .processingASR, cleared
    // when ai.turn.end arrives or the session ends. Lives here so both the
    // middleware dispatch path and the timeout tasks can access it.
    let turnTimeoutTracking = TurnTimeoutTracking()
    let speechCaptureGate = SpeechCaptureGate()
    let evaluationArrival = EvaluationArrivalBox()
    let ttsDispatcher = TTSFrameDispatcher(decoder: resolvedContainer.ttsDecoder())
    let ttsTrace = TTSStreamTrace()

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

        guard case let .speakingRoom(.session(event)) = action else {
            return next(action)
        }

        var session = store.state.speakingRoom.session
        let preEventCount = session.userTurnCount
        let previousPhase = session.phase
        let effects = SpeechSessionMachine.reduce(&session, event: event)
        // Keep the audio loop's "current count" in sync. The audio loop
        // computes `turnID = "turn-\(count + 1)"` at speech-end time —
        // this is the same value the machine's reduce will use to do the
        // transition's count increment, so the two never drift.
        turnCounter.set(session.userTurnCount)

        // B15: flag to start the turn timeout when we enter .processingASR from
        // .recording. Sub-stage timers are scheduled as `.task(id:)` so they
        // cancel independently of the transport loop.
        let enteredProcessing = previousPhase == .recording && session.phase == .processingASR
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
                ttsDispatcher: ttsDispatcher,
                ttsTrace: ttsTrace,
                usesAutoVAD: store.state.featureFlags.isEnabled(.voiceVadAuto)
            )
        }
        let timeoutEffects = processingTimeoutEffects(
            from: previousPhase,
            to: session.phase,
            enteredProcessing: enteredProcessing,
            enteredRecording: enteredRecording,
            turnTimeoutTracking: turnTimeoutTracking,
            speechCaptureGate: speechCaptureGate,
            evaluationArrival: evaluationArrival,
            tracker: resolvedContainer.tracker(),
            timeouts: resolvedContainer.processingTimeouts()
        )
        return .merge([apply] + interpreted + timeoutEffects)
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
internal final class SpeechCaptureGate: @unchecked Sendable {
    private struct State {
        var open = false
    }

    private let storage = OSAllocatedUnfairLock<State>(initialState: State())

    func beginSpeech() {
        storage.withLock { $0.open = true }
    }

    /// Normal turn end (`vadSpeechEnd` / `endManualSpeech`).
    func endSpeech() {
        storage.withLock { $0.open = false }
    }

    /// I20 recording abort. Identical wire effect to `endSpeech`; kept as a
    /// separate entry point because the call site also relies on the closed
    /// gate to swallow the trailing `speechEnded`.
    func abort() {
        storage.withLock { $0.open = false }
    }

    var isOpen: Bool {
        storage.withLock { $0.open }
    }

    /// PCM only leaves the device while the user has an utterance open.
    var shouldForwardPCM: Bool {
        storage.withLock { $0.open }
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
    ttsDispatcher: TTSFrameDispatcher,
    ttsTrace: TTSStreamTrace,
    usesAutoVAD: Bool = false
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
    case let .trackTransition(from, to):
        // `trackTransition` fires alongside the reducer's `speech_session_transition`
        // event. We piggy-back the delta timing on the same transition so the
        // iOS log can match the backend's stage markers without a second
        // tracker stream.
        timings.mark(
            event: "phase_transition",
            properties: [
                "from": from.rawValue,
                "to": to.rawValue,
                "stage": to.stageTag,
            ]
        )
    }

    switch effect {
    case .createSession:
        // B15 total-cap is armed by `processingTimeoutEffects` when we enter
        // processingASR from recording — not from createSession.
        return .merge(
            .task {
                do {
                    try await speechClient.startSession()
                    await audioEngine.setSpeechBoundaryMode(usesAutoVAD ? .autoVAD : .tapToStart)
                    try await audioEngine.startCapture()
                } catch let error as AudioEnginePermissionError {
                    let message: String
                    switch error {
                    case .microphoneDenied:
                        message = "无法访问麦克风，请在系统设置中允许 FluentWork 使用麦克风。"
                    }
                    return .speakingRoom(.session(.failed(message)))
                } catch {
                    return .speakingRoom(.session(.failed(error.localizedDescription)))
                }
                return nil
            },
            .task(id: SpeechSessionTaskID.transportEvents) {
                for await event in speechClient.transportEvents() {
                    if Task.isCancelled { return nil }

                    // B14 debug: log all incoming transport control events to diagnose
                    // missing feedback.badge frames. Remove after root cause is confirmed.
                    #if DEBUG
                    if case let .control(frame) = event {
                        let typeTag: String
                        switch frame {
                        case .feedbackBadge:  typeTag = "feedback.badge"
                        case .userSpeechStart: typeTag = "user.speech.start"
                        case .userSpeechEnd:   typeTag = "user.speech.end"
                        case .clientTurnAbort: typeTag = "client.turn.abort"
                        case let .aiTurnEnd(_, outcome, _):
                            typeTag = "ai.turn.end" + (outcome.map { "(\($0.rawValue))" } ?? "")
                        case .ping:            typeTag = "ping"
                        case .pong:            typeTag = "pong"
                        case .clientASRTranscription: typeTag = "client.asr.transcription"
                        case .sessionReady:    typeTag = "session.ready"
                        case .sessionStart:   typeTag = "session.start"
                        case .aiTextDelta:    typeTag = "ai.text.delta"
                        case .aiAudioChunk:   typeTag = "ai.audio.chunk"
                        case .aiTTSStart:     typeTag = "ai.tts.start"
                        case .aiTTSEnd:       typeTag = "ai.tts.end"
                        case .interrupt:       typeTag = "interrupt"
                        case .sessionEnd:      typeTag = "session.end"
                        case .error:           typeTag = "error"
                        case .auth, .handshake: typeTag = "<auth/handshake>"
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

                    switch event {
                    case let .audio(frame):
                        await dispatchBox.dispatch(.speakingRoom(.session(.aiFirstAudioChunk)))
                        timings.mark(
                            event: "ai_first_chunk",
                            properties: [
                                "sequence": String(frame.sequence),
                                "payload_bytes": String(frame.opusPayload.count),
                            ]
                        )
                        do {
                            let consumedByTTS = try ttsDispatcher.handle(audio: frame)
                            if consumedByTTS {
                                let count = ttsTrace.recordAudio()
                                if count == 1 {
                                    container.tracker().track(
                                        event: "tts_first_audio",
                                        properties: [
                                            "turn_id": ttsDispatcher.activeTurnID() ?? "nil",
                                            "sequence": String(frame.sequence),
                                            "payload_bytes": String(frame.opusPayload.count),
                                        ]
                                    )
                                }
                            } else {
                                await audioEngine.play(frame: frame)
                            }
                        } catch {
                            container.tracker().track(
                                event: "tts_decoder_failed",
                                properties: [
                                    "phase": "feed",
                                    "sequence": String(frame.sequence),
                                    "error": String(describing: error),
                                ]
                            )
                        }

                    case let .control(.aiTTSStart(turnID, voiceID, sampleRate, codec)):
                        do {
                            try ttsDispatcher.handle(
                                control: .aiTTSStart(
                                    turnID: turnID,
                                    voiceID: voiceID,
                                    sampleRate: sampleRate,
                                    codec: codec
                                )
                            )
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
                        } catch {
                            container.tracker().track(
                                event: "tts_decoder_failed",
                                properties: [
                                    "phase": "prepare",
                                    "turn_id": turnID,
                                    "error": String(describing: error),
                                ]
                            )
                        }

                    case let .control(.aiTTSEnd(turnID, completionStatus, durationMs)):
                        do {
                            try ttsDispatcher.handle(
                                control: .aiTTSEnd(
                                    turnID: turnID,
                                    completionStatus: completionStatus,
                                    durationMs: durationMs
                                )
                            )
                            container.tracker().track(
                                event: "tts_end",
                                properties: [
                                    "turn_id": turnID,
                                    "completion_status": completionStatus,
                                    "duration_ms": durationMs.map(String.init) ?? "nil",
                                    "audio_frames": String(ttsTrace.audioFrameCount()),
                                ]
                            )
                        } catch {
                            container.tracker().track(
                                event: "tts_decoder_failed",
                                properties: [
                                    "phase": "finish",
                                    "turn_id": turnID,
                                    "error": String(describing: error),
                                ]
                            )
                        }

                    case let .control(.feedbackBadge(badge, phraseBlockID, tier, turnID)):
                        // WSS has no eval.frame. `feedback.badge` is the turn-level
                        // signal that can leave `.waitingForEvaluation`. Session
                        // review stays on REST (I16).
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

                    case let .control(.aiTurnEnd(turnID, outcome, logID)):
                        // B15-I3: capture the vendor log_id from the first ai.turn.end.
                        // setLogID is idempotent (only the first call stores the value).
                        timings.setLogID(logID)
                        // B15: ai.turn.end arrived — cancel the turn timeout timer so it
                        // doesn't fire and cause a duplicate session.end. Safe to call
                        // even if the timer was never started.
                        turnTimeoutTracking?.disarm()
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

                    case let .control(.aiTextDelta(text)):
                        await dispatchBox.dispatch(
                            .speakingRoom(.aiTurnTextDelta(text: text, turnID: nil))
                        )

                    case let .control(.clientASRTranscription(text, turnID)):
                        // Display-layer transcript plus the ASR → LLM hop.
                        // `.session(.serverASRReceived)` advances processingASR →
                        // processingLLM; `.serverASRReceived` still updates the
                        // speaking-room transcript overlay.
                        await dispatchBox.dispatch(
                            .speakingRoom(.session(.serverASRReceived(text: text, turnID: turnID)))
                        )
                        await dispatchBox.dispatch(
                            .speakingRoom(.serverASRReceived(text: text, turnID: turnID))
                        )
                        tracker.track(
                            event: "server_asr_received_full",
                            properties: [
                                "turn_id": turnID ?? "nil",
                                "text_bytes": String(text.utf8.count),
                                "text": text,
                            ]
                        )
                        timings.mark(
                            event: "server_asr_received",
                            properties: [
                                "turn_id": turnID ?? "nil",
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

                    case let .diagnostic(.receiveLatency(frameType, sizeBytes, elapsedMs)):
                        tracker.track(
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
                    case let .diagnostic(.audioFrameDropped(sequence, watermark, dropped)):
                        tracker.track(
                            event: "transport_audio_dropped",
                            properties: [
                                "sequence": String(sequence),
                                "watermark": String(watermark),
                                "dropped": String(dropped),
                            ]
                        )

                    default:
                        guard let mapped = SocketTransportEventMapper.speakingRoomAction(for: event),
                              let action = SpeakingRoomAction(mapped)
                        else {
                            continue
                        }
                        await dispatchBox.dispatch(.speakingRoom(action))
                    }
                }
                return nil
            },
            .task(id: SpeechSessionTaskID.audioEngineEvents) {
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
                            speechCaptureGate.endSpeech()

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
                            guard speechCaptureGate.shouldForwardPCM else { continue }

                            try await speechClient.sendAudioPCM(data)
                        } catch {
                            await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                            return nil
                        }

                    case .interruptedBySystem:
                        await dispatchBox.dispatch(.speakingRoom(.session(.interruptedBySystem)))

                    case .systemInterruptEnded:
                        await dispatchBox.dispatch(.speakingRoom(.session(.systemInterruptEnded)))

                    case let .routeChanged(reason):
                        timings.mark(event: "audio_route_changed", properties: ["reason": reason])
                        await audioEngine.reconfigureForRouteChange()

                    case let .failed(message):
                        timings.mark(event: "audio_engine_failed", properties: ["message": message])
                        await dispatchBox.dispatch(.speakingRoom(.session(.failed(message))))
                        return nil
                    }
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
            let turnID = ttsDispatcher.activeTurnID() ?? "nil"
            try? ttsDispatcher.interrupt()
            container.tracker().track(
                event: "tts_interrupt",
                properties: ["turn_id": turnID]
            )
            await audioEngine.interruptNow()
        }

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
        // Clear TTS binding on the middleware thread so a leftover start cannot
        // swallow the next session's PCM if the host restarts immediately.
        try? ttsDispatcher.reset()
        return .merge(
            .cancel(id: SpeechSessionTaskID.transportEvents),
            .cancel(id: SpeechSessionTaskID.audioEngineEvents),
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
        try? ttsDispatcher.reset()
        let backgroundTasks = container.backgroundTaskPort()
        return .merge(
            .cancel(id: SpeechSessionTaskID.transportEvents),
            .cancel(id: SpeechSessionTaskID.audioEngineEvents),
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

    case let .trackTransition(from, to):
        return .fireAndForget {
            tracker.track(
                event: "speech_session_transition",
                properties: [
                    "from": from.rawValue,
                    "to": to.rawValue,
                    "from_label": from.label,
                    "to_label": to.label,
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

    if previousPhase == .processingASR, newPhase == .processingLLM {
        effects.append(.cancel(id: SpeechSessionTaskID.processingASRTimeout))
        effects.append(scheduleProcessingTimeoutTask(stage: .llm, timeouts: timeouts, tracker: tracker))
    }

    if previousPhase == .processingLLM, newPhase == .processingReview {
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

    if previousPhase != .waitingForEvaluation, newPhase == .waitingForEvaluation {
        if evaluationArrival.consume() {
            effects.append(.task {
                return .speakingRoom(.session(.evaluationReceived))
            })
        } else {
            effects.append(scheduleEvaluationWaitTask(timeouts: timeouts))
        }
    }

    if previousPhase == .waitingForEvaluation, newPhase != .waitingForEvaluation {
        effects.append(.cancel(id: SpeechSessionTaskID.evaluationTimeout))
    }

    return effects
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
    stage: ProcessingSubStage,
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
    ]
    if includeTotalCap {
        effects.append(.cancel(id: SpeechSessionTaskID.turnTimeout))
    }
    return .merge(effects)
}

private final class MainActorActionBox: @unchecked Sendable {
    private let dispatch: @MainActor (AppAction) -> Void

    init(dispatch: @escaping @MainActor (AppAction) -> Void) {
        self.dispatch = dispatch
    }

    func dispatch(_ action: AppAction) async {
        await dispatch(action)
    }
}
