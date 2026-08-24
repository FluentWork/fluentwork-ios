import TGReduxKit

public enum SpeakingRoomPhase: String, Equatable, Sendable {
    case idle
    case connecting
    case waitingUser
    case processing
    case degradedText
    case failed
}

public struct SpeakingRoomState: Equatable, Sendable {
    public var phase: SpeakingRoomPhase
    public var liveTranscript: String
    public var isBootstrapReady: Bool
    public var lastBadge: String?
    public var badgeHits: Int
    public var failureReason: String?

    public init(
        phase: SpeakingRoomPhase = .idle,
        liveTranscript: String = "",
        isBootstrapReady: Bool = false,
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        failureReason: String? = nil
    ) {
        self.phase = phase
        self.liveTranscript = liveTranscript
        self.isBootstrapReady = isBootstrapReady
        self.lastBadge = lastBadge
        self.badgeHits = badgeHits
        self.failureReason = failureReason
    }
}

public enum SpeakingRoomAction: Equatable, Sendable {
    case sessionStartTapped
    case socketReady
    case userSpeechCaptured(String)
    case badgeHit(String)
    case networkDowngraded
    case bootstrapReady(Bool)
    case failed(String)
}

@MainActor
public let speakingRoomReducer: Reducer<SpeakingRoomState, SpeakingRoomAction> = { state, action in
    switch action {
    case .sessionStartTapped:
        state.phase = .connecting
        state.liveTranscript = ""
        state.failureReason = nil

    case .socketReady:
        state.phase = .waitingUser

    case let .userSpeechCaptured(transcript):
        state.phase = .processing
        state.liveTranscript = transcript

    case let .badgeHit(badge):
        state.lastBadge = badge
        state.badgeHits += 1

    case .networkDowngraded:
        state.phase = .degradedText

    case let .bootstrapReady(isReady):
        state.isBootstrapReady = isReady

    case let .failed(message):
        state.phase = .failed
        state.failureReason = message
    }
}
