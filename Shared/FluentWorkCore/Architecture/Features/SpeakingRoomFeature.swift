import TGReduxKit

public struct SpeakingRoomState: Equatable, Sendable, State {
    public var session: SpeechSessionState
    public var liveTranscript: String
    public var isBootstrapReady: Bool
    public var lastBadge: String?
    public var badgeHits: Int

    public var phase: SpeechSessionPhase { session.phase }
    public var failureReason: String? { session.failureReason }

    public init(
        session: SpeechSessionState = .initial,
        liveTranscript: String = "",
        isBootstrapReady: Bool = false,
        lastBadge: String? = nil,
        badgeHits: Int = 0
    ) {
        self.session = session
        self.liveTranscript = liveTranscript
        self.isBootstrapReady = isBootstrapReady
        self.lastBadge = lastBadge
        self.badgeHits = badgeHits
    }

    /// Test / Host helper mirroring the previous phase-centric initializer.
    public init(
        phase: SpeechSessionPhase,
        liveTranscript: String = "",
        isBootstrapReady: Bool = false,
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        failureReason: String? = nil
    ) {
        self.init(
            session: SpeechSessionState(phase: phase, failureReason: failureReason),
            liveTranscript: liveTranscript,
            isBootstrapReady: isBootstrapReady,
            lastBadge: lastBadge,
            badgeHits: badgeHits
        )
    }
}

public enum SpeakingRoomAction: Equatable, Sendable, Action {
    /// Domain event for the pure SpeechSession machine (Middleware-owned).
    case session(SpeechSessionEvent)
    /// State snapshot applied after Middleware runs the machine.
    case applySession(SpeechSessionState)
    /// Display-only — must not enter SpeechSessionMachine (§2.2 badgeHit).
    case badgeHit(String)
    case bootstrapReady(Bool)
    /// Local transcript overlay text; does not drive the session phase machine.
    case userSpeechCaptured(String)
}

public let speakingRoomReducer: Reducer<SpeakingRoomState, SpeakingRoomAction> = { state, action in
    switch action {
    case .session:
        // Interpreted by `speechSessionMiddleware`; reducer ignores raw events.
        break

    case let .applySession(session):
        state.session = session
        if session.phase == .connecting {
            state.liveTranscript = ""
            state.lastBadge = nil
            state.badgeHits = 0
        }

    case let .badgeHit(badge):
        state.lastBadge = badge
        state.badgeHits += 1

    case let .bootstrapReady(isReady):
        state.isBootstrapReady = isReady

    case let .userSpeechCaptured(transcript):
        state.liveTranscript = transcript
    }
}
