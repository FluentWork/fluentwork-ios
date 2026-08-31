import FactoryKit
import FluentWorkDiagnostics
import FluentWorkNetworking
import Foundation
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

    return { store, action, next in
        guard case let .speakingRoom(.session(event)) = action else {
            return next(action)
        }

        var session = store.state.speakingRoom.session
        let effects = SpeechSessionMachine.reduce(&session, event: event)
        let apply = next(.speakingRoom(.applySession(session)))
        let interpreted = effects.map {
            interpretSpeechSessionSideEffect(
                $0,
                container: resolvedContainer,
                dispatch: { store.dispatch($0) }
            )
        }
        return .merge([apply] + interpreted)
    }
}

private func interpretSpeechSessionSideEffect(
    _ effect: SpeechSessionSideEffect,
    container: Container,
    dispatch: @escaping @MainActor (AppAction) -> Void
) -> Effect<AppAction> {
    let audioEngine = container.audioEngine()
    let speechClient = container.speechSessionClient()
    let tracker = container.tracker()
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
                for await event in audioEngine.events() {
                    if Task.isCancelled { return nil }

                    switch event {
                    case .speechStarted:
                        do {
                            try await speechClient.sendSpeechBoundary(started: true)
                            await dispatchBox.dispatch(.speakingRoom(.session(.vadSpeechStart)))
                        } catch {
                            await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                            return nil
                        }

                    case .speechEnded:
                        do {
                            try await speechClient.sendSpeechBoundary(started: false)
                            await dispatchBox.dispatch(.speakingRoom(.session(.vadSpeechEnd)))
                        } catch {
                            await dispatchBox.dispatch(.speakingRoom(.session(.failed(error.localizedDescription))))
                            return nil
                        }

                    case let .pcmChunk(data):
                        do {
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
