import FluentWorkFeatureFlags
import TGReduxKit

public enum BootstrapStatus: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

public struct BootstrapSnapshot: Equatable, Sendable {
    public var featureFlags: FeatureFlagSnapshot
    public var preferredSurface: WorkspaceSurface

    public init(
        featureFlags: FeatureFlagSnapshot,
        preferredSurface: WorkspaceSurface
    ) {
        self.featureFlags = featureFlags
        self.preferredSurface = preferredSurface
    }

    public static let preview = BootstrapSnapshot(
        featureFlags: .firstWave,
        preferredSurface: .speakingRoom
    )
}

public struct AppState: Equatable, Sendable, State {
    public var bootstrapStatus: BootstrapStatus
    public var lastErrorMessage: String?
    public var featureFlags: FeatureFlagsState
    public var auth: AuthState
    public var speakingRoom: SpeakingRoomState
    public var review: ReviewState
    public var corpus: CorpusState
    public var workspace: WorkspaceState
    public var network: NetworkConnectivityState
    public var navigation: AppNavigationState

    public init(
        bootstrapStatus: BootstrapStatus = .idle,
        lastErrorMessage: String? = nil,
        featureFlags: FeatureFlagsState = FeatureFlagsState(),
        auth: AuthState = AuthState(),
        speakingRoom: SpeakingRoomState = SpeakingRoomState(),
        review: ReviewState = ReviewState(),
        corpus: CorpusState = CorpusState(),
        workspace: WorkspaceState = WorkspaceState(),
        network: NetworkConnectivityState = NetworkConnectivityState(),
        navigation: AppNavigationState = AppNavigationState()
    ) {
        self.bootstrapStatus = bootstrapStatus
        self.lastErrorMessage = lastErrorMessage
        self.featureFlags = featureFlags
        self.auth = auth
        self.speakingRoom = speakingRoom
        self.review = review
        self.corpus = corpus
        self.workspace = workspace
        self.network = network
        self.navigation = navigation
    }

    public static let initial = AppState()
}

public enum LifecycleAction: Equatable, Sendable, Action {
    case appLaunched
    case bootstrapStarted
    case bootstrapSucceeded(BootstrapSnapshot)
    case bootstrapFailed(String)
}

public enum AppAction: Equatable, Sendable, Action {
    case lifecycle(LifecycleAction)
    case featureFlags(FeatureFlagsAction)
    case auth(AuthAction)
    case speakingRoom(SpeakingRoomAction)
    case review(ReviewAction)
    case corpus(CorpusAction)
    case workspace(WorkspaceAction)
    case network(NetworkConnectivityAction)
    case navigation(AppNavigationAction)
}
