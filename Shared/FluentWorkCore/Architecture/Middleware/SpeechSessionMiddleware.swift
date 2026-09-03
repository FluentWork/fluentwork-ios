import FactoryKit
import FluentWorkDiagnostics
import FluentWorkNetworking
import Foundation
import os
import TGReduxKit

public enum SpeechSessionTaskID {
    public static let reconnectWindow: CancellationID = "speechSession.reconnectWindow"
    public static let transportEvents: CancellationID = "speechSession.transportEvents"
    public static let audioEngineEvents: CancellationID = "speechSession.audioEngineEvents"
}

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

    return { store, action, next in
        guard case let .speakingRoom(.session(event)) = action else {
            return next(action)
        }

        var session = store.state.speakingRoom.session
        let preEventCount = session.userTurnCount
        let effects = SpeechSessionMachine.reduce(&session, event: event)
        // Keep the audio loop's "current count" in sync. The audio loop
        // computes `turnID = "turn-\(count + 1)"` at speech-end time —
        // this is the same value the machine's reduce will use to do the
        // transition's count increment, so the two never drift.
        turnCounter.set(session.userTurnCount)
        let apply = next(.speakingRoom(.applySession(session)))
        let interpreted = effects.map {
            interpretSpeechSessionSideEffect(
                $0,
                container: resolvedContainer,
                dispatch: { store.dispatch($0) },
                pendingTurnID: pendingTurnID(for: event, currentCount: preEventCount),
                turnCounter: turnCounter,
                timings: timings
            )
        }
        return .merge([apply] + interpreted)
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

private func interpretSpeechSessionSideEffect(
    _ effect: SpeechSessionSideEffect,
    container: Container,
    dispatch: @escaping @MainActor (AppAction) -> Void,
    pendingTurnID: String?,
    turnCounter: TurnCountBox,
    timings: SpeechSessionTimingsRecorder
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
    case .stopPlayback:
        timings.mark(event: "playback_stop")
    case .startReconnectWindow:
        timings.mark(event: "reconnect_window_start")
    case .endSession:
        timings.mark(event: "session_end")
    case .sendTextMessage:
        timings.mark(event: "degraded_text_send")
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
        return .merge(
            .task {
                do {
                    try await speechClient.startSession()
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
                        case .aiTurnEnd:      typeTag = "ai.turn.end"
                        case .ping:            typeTag = "ping"
                        case .pong:            typeTag = "pong"
                        case .clientASRTranscription: typeTag = "client.asr.transcription"
                        case .sessionReady:    typeTag = "session.ready"
                        case .sessionStart:   typeTag = "session.start"
                        case .aiTextDelta:    typeTag = "ai.text.delta"
                        case .aiAudioChunk:   typeTag = "ai.audio.chunk"
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
                        await audioEngine.play(frame: frame)

                    case let .control(.aiTurnEnd(turnID)):
                        await dispatchBox.dispatch(.speakingRoom(.session(.aiTurnEnd)))
                        await dispatchBox.dispatch(.speakingRoom(.aiTurnFinalized(turnID: turnID)))
                        if let turnID {
                            timings.markTurnEnded(turnID, source: "ios", stage: "ai_turn_end")
                        }
                        timings.mark(
                            event: "ai_turn_end",
                            properties: ["turn_id": turnID ?? "nil"]
                        )

                    case let .control(.aiTextDelta(text)):
                        await dispatchBox.dispatch(
                            .speakingRoom(.aiTurnTextDelta(text: text, turnID: nil))
                        )

                    case let .control(.clientASRTranscription(text, turnID)):
                        // Display-layer transcript (not a Machine event):
                        // `.session(.serverASRReceived)` is intentionally a
                        // no-op in SpeechSessionMachine.
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
                            
                            try await speechClient.sendAudioPCM(data)
                        } catch {
                            await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                            return nil
                        }

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

    case .stopPlayback:
        return .fireAndForget {
            await audioEngine.interruptNow()
        }

    case .startReconnectWindow:
        return .task(id: SpeechSessionTaskID.reconnectWindow) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return nil }
            await dispatchBox.dispatch(.speakingRoom(.session(.reconnectTimedOut)))
            return nil
        }

    case .endSession:
        return .merge(
            .cancel(id: SpeechSessionTaskID.transportEvents),
            .cancel(id: SpeechSessionTaskID.audioEngineEvents),
            .fireAndForget {
                let sessionID = await speechClient.activeSessionID()
                await audioEngine.stopCapture()
                await speechClient.endSession()
                if let sessionID {
                    await dispatchBox.dispatch(.speakingRoom(.sessionIDCaptured(sessionID)))
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
                ]
            )
        }
    }
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
