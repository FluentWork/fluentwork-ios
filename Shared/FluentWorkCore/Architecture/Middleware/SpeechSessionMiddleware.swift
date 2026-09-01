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
                turnCounter: turnCounter
            )
        }
        return .merge([apply] + interpreted)
    }
}

/// Computes the turnID the middleware should send to the backend for an
/// end-of-utterance boundary (`vadSpeechEnd` / `holdEnd`). Other events
/// return `nil`; the rule lives here so the wire format and the
/// `userTurnCount` increment in the machine stay in lockstep.
private func pendingTurnID(
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
private final class TurnCountBox: Sendable {
    private let storage = OSAllocatedUnfairLock<Int>(initialState: 0)

    func get() -> Int { storage.withLock { $0 } }
    func set(_ newValue: Int) { storage.withLock { $0 = newValue } }
}

private func interpretSpeechSessionSideEffect(
    _ effect: SpeechSessionSideEffect,
    container: Container,
    dispatch: @escaping @MainActor (AppAction) -> Void,
    pendingTurnID: String?,
    turnCounter: TurnCountBox
) -> Effect<AppAction> {
    let audioEngine = container.audioEngine()
    let speechClient = container.speechSessionClient()
    let tracker = container.tracker()
    let clientASRTranscriber = container.clientASRTranscriber()
    let dispatchBox = MainActorActionBox(dispatch: dispatch)

    switch effect {
    case .createSession:
        return .merge(
            .task {
                do {
                    try await speechClient.startSession()
                    try await audioEngine.startCapture()
                } catch {
                    return .speakingRoom(.session(.failed(error.localizedDescription)))
                }
                return nil
            },
            .task(id: SpeechSessionTaskID.transportEvents) {
                for await event in speechClient.transportEvents() {
                    if Task.isCancelled { return nil }

                    switch event {
                    case let .audio(frame):
                        await dispatchBox.dispatch(.speakingRoom(.session(.aiFirstAudioChunk)))
                        await audioEngine.play(frame: frame)

                    case .control(.aiTurnEnd(turnID: _)):
                        await dispatchBox.dispatch(.speakingRoom(.session(.aiTurnEnd)))

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
                            await dispatchBox.dispatch(.speakingRoom(.session(.vadSpeechStart)))
                        } catch {
                            await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                            return nil
                        }

                    case .speechEnded:
                        do {
                            isCapturingSpeech = false
                            
                            // `turnCounter` is updated by the session event
                            // handler *after* every reduce, so by the time
                            // `.speechEnded` arrives the box already holds
                            // the post-`.vadSpeechStart` count (which
                            // matches the count BEFORE the just-finished
                            // turn's increment). The turn we just finished
                            // is therefore `count + 1`.
                            let turnID = "turn-\(turnCounter.get() + 1)"
                            
                            // B13: Attempt client-side ASR transcription with buffered PCM
                            let clientASRText = await transcribeWithClientASR(
                                transcriber: clientASRTranscriber,
                                tracker: tracker,
                                turnID: turnID,
                                pcmChunks: pcmBuffer
                            )
                            
                            // Display the transcribed text in the UI
                            if let text = clientASRText, !text.isEmpty {
                                await dispatchBox.dispatch(.speakingRoom(.userSpeechCaptured(text)))
                            }
                            
                            try await speechClient.sendSpeechBoundary(
                                started: false,
                                turnID: turnID,
                                text: clientASRText
                            )
                            tracker.track(
                                event: "speech_turn_ended",
                                properties: [
                                    "turn_id": turnID,
                                    "source": "ios",
                                    "stage": "asr",
                                ]
                            )
                            await dispatchBox.dispatch(.speakingRoom(.session(.vadSpeechEnd(turnID: turnID))))
                            
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
                await audioEngine.stopCapture()
                await speechClient.endSession()
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

/// B13: Attempt client-side ASR transcription with 800ms timeout.
/// Returns transcribed text on success, nil on failure/timeout (falls back to server-side ASR).
private func transcribeWithClientASR(
    transcriber: ClientASRTranscriber,
    tracker: TrackerClientProtocol,
    turnID: String,
    pcmChunks: [Data]
) async -> String? {
    // Create a stream from buffered PCM chunks
    let pcmStream = AsyncStream<Data> { continuation in
        for chunk in pcmChunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
    
    let startTime = ContinuousClock.now
    
    do {
        // 800ms timeout as per B13 spec
        let text = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await transcriber.transcribe(pcm: pcmStream)
            }
            
            group.addTask {
                try await Task.sleep(for: .milliseconds(800))
                return nil // Timeout sentinel
            }
            
            guard let result = try await group.next() else {
                throw ClientASRError.notAvailable
            }
            
            group.cancelAll()
            
            if let text = result {
                return text
            } else {
                // Timeout occurred
                throw ClientASRError.notAvailable
            }
        }
        
        let elapsed = ContinuousClock.now - startTime
        let elapsedMs = Int(elapsed.components.seconds * 1000 + Int64(elapsed.components.attoseconds) / 1_000_000_000_000_000)
        
        if text.isEmpty {
            // Empty result treated as skip
            tracker.track(
                event: "speech_client_asr_skipped",
                properties: [
                    "turn_id": turnID,
                    "reason": "empty_result",
                    "source": "ios",
                ]
            )
            return nil
        }
        
        tracker.track(
            event: "speech_client_asr_completed",
            properties: [
                "turn_id": turnID,
                "elapsed_ms": "\(elapsedMs)",
                "text_length": "\(text.count)",
                "source": "ios",
            ]
        )
        
        return text
        
    } catch is CancellationError {
        tracker.track(
            event: "speech_client_asr_skipped",
            properties: [
                "turn_id": turnID,
                "reason": "timeout",
                "source": "ios",
            ]
        )
        return nil
        
    } catch let error as ClientASRError {
        let reason: String
        switch error {
        case .notAvailable:
            reason = "not_available"
        case .timeout:
            reason = "timeout"
        case .authorizationDenied:
            reason = "authorization_denied"
        case .unsupportedFormat:
            reason = "unsupported_format"
        case .engineError:
            reason = "engine_error"
        }
        
        tracker.track(
            event: "speech_client_asr_failed",
            properties: [
                "turn_id": turnID,
                "error_code": reason,
                "source": "ios",
            ]
        )
        return nil
        
    } catch {
        tracker.track(
            event: "speech_client_asr_failed",
            properties: [
                "turn_id": turnID,
                "error_code": "unknown",
                "source": "ios",
            ]
        )
        return nil
    }
}
