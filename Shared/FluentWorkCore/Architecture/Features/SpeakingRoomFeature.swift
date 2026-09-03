import TGReduxKit

public struct SpeakingRoomState: Equatable, Sendable, State {
    public var session: SpeechSessionState
    public var liveTranscript: String
    public var isBootstrapReady: Bool
    public var lastBadge: String?
    public var badgeHits: Int
    /// Session bound by the active `DefaultSpeechSessionClient`, captured on
    /// session end so the UI can navigate to that session's review page.
    public var lastSessionID: String?

    public var phase: SpeechSessionPhase { session.phase }
    public var failureReason: String? { session.failureReason }

    public init(
        session: SpeechSessionState = .initial,
        liveTranscript: String = "",
        isBootstrapReady: Bool = false,
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        lastSessionID: String? = nil
    ) {
        self.session = session
        self.liveTranscript = liveTranscript
        self.isBootstrapReady = isBootstrapReady
        self.lastBadge = lastBadge
        self.badgeHits = badgeHits
        self.lastSessionID = lastSessionID
    }

    /// Test / Host helper mirroring the previous phase-centric initializer.
    public init(
        phase: SpeechSessionPhase,
        liveTranscript: String = "",
        isBootstrapReady: Bool = false,
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        failureReason: String? = nil,
        lastSessionID: String? = nil
    ) {
        self.init(
            session: SpeechSessionState(phase: phase, failureReason: failureReason),
            liveTranscript: liveTranscript,
            isBootstrapReady: isBootstrapReady,
            lastBadge: lastBadge,
            badgeHits: badgeHits,
            lastSessionID: lastSessionID
        )
    }
}

public enum SpeakingRoomAction: Equatable, Sendable, Action {
    /// Domain event for the pure SpeechSession machine (Middleware-owned).
    case session(SpeechSessionEvent)
    /// State snapshot applied after Middleware runs the machine.
    case applySession(SpeechSessionState)
    /// Display-only — must not enter SpeechSessionMachine (§2.2 badgeHit).
    ///
    /// Carries the optional B12 enrichment (`phraseBlockID`, `tier`, `turnID`)
    /// so the cross-cutting reducer can mirror the hit into `badgeFeedback`
    /// with the same `turnID` the backend used for dedupe. Tests + the host
    /// debug screen still pass just a badge string; the optional fields
    /// default to `nil`.
    case badgeHit(
        badge: String,
        phraseBlockID: String? = nil,
        tier: BadgeFeedEntry.Tier? = nil,
        turnID: String? = nil
    )
    /// Captures the session id bound by the speech client right before the
    /// transport closes, so the ended-state UI can offer "查看回顾".
    case sessionIDCaptured(String)
    case bootstrapReady(Bool)
    /// Local transcript overlay text; does not drive the session phase machine.
    case userSpeechCaptured(String)
    /// B14: Server-side ASR transcript received via WSS relay from the voice provider.
    /// When this arrives, the middleware immediately calls `sendSpeechBoundary`
    /// with the authoritative server text (for badge hit detection) and dispatches
    /// this action so the reducer updates `liveTranscript` for display.
    case serverASRReceived(text: String, turnID: String?)
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

    case let .badgeHit(badge, _, _, _):
        // Display counter ignores enrichment; downstream `badgeFeedback.ingest`
        // owns the structured payload (phraseBlockID / tier / turnID).
        state.lastBadge = badge
        state.badgeHits += 1

    case let .sessionIDCaptured(sessionID):
        state.lastSessionID = sessionID

    case let .bootstrapReady(isReady):
        state.isBootstrapReady = isReady

    case let .userSpeechCaptured(transcript):
        state.liveTranscript = transcript

    case let .serverASRReceived(text, _):
        state.liveTranscript = text
    }
}
