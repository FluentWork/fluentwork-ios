import FactoryKit
import FluentWorkDiagnostics
import Foundation
import TGReduxKit

public enum SpeechSessionTaskID {
    public static let reconnectWindow: CancellationID = "speechSession.reconnectWindow"
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
        return .task {
            do {
                try await speechClient.startSession()
            } catch {
                return .speakingRoom(.session(.failed(error.localizedDescription)))
            }
            return nil
        }

    case .sendInterrupt:
        return .fireAndForget {
            try? await speechClient.submitTranscript("__interrupt__")
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
        return .fireAndForget {
            await speechClient.endSession()
        }

    case .sendTextMessage:
        return .task {
            do {
                // Text body is owned by UI later; keep wiring with empty payload for now.
                try await speechClient.sendDegradedTextMessage("")
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
