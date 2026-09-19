import Testing
import TGReduxKit

@testable import FluentWorkCore

/// Bring a session to `.aiSpeaking`: socket up **and** microphone proven to deliver.
///
/// `.connecting` waits on both halves (`SpeechSessionEvent.captureLive`), so a
/// test that dispatches only `.socketReady` stays in `.connecting` until the 10s
/// `connectWait` watchdog turns the session into `.failed("连接超时，请重试")`.
///
/// When the gate landed, forty call sites did exactly that — and every one of
/// them meant the same thing: *"the session is live, now test the thing I am
/// actually about."* This function says that once, in one place, so the next
/// change to the readiness rule updates one definition instead of forty
/// dispatch pairs that would drift apart silently.
///
/// **Production does not reach `.aiSpeaking` this way.** The engine yields
/// `AudioEngineEvent.captureFirstBuffer`, the audio pump maps it, and the
/// middleware dispatches. Tests whose subject is *what happens after* the
/// session is live manufacture the precondition directly — that is what this
/// is for. The wiring itself is pinned separately, by
/// `captureFirstBufferOpensTheSession`.
///
/// - Parameters:
///   - socketReady: pass `false` for the half-readiness cases (a test about what
///     a half-open session does); the default is the full precondition.
///   - captureLive: same, for the other half.
@MainActor
func makeSessionLive(
    _ store: Store<AppState, AppAction>,
    socketReady: Bool = true,
    captureLive: Bool = true
) {
    if socketReady { store.dispatch(.speakingRoom(.session(.socketReady))) }
    if captureLive { store.dispatch(.speakingRoom(.session(.captureLive))) }
}
