import FluentWorkPluginSupport
import TGReduxKit

public enum WorkspaceSurface: String, Equatable, Sendable {
    case workbench
    case speakingRoom
    case review
}

public struct WorkspaceState: Equatable, Sendable, State {
    public var activeSurface: WorkspaceSurface
    public var highlightedBadge: String?
    public var badgeFeedCount: Int
    public var isBootstrapComplete: Bool
    public var availableModules: [FeaturePluginDescriptor]

    public init(
        activeSurface: WorkspaceSurface = .workbench,
        highlightedBadge: String? = nil,
        badgeFeedCount: Int = 0,
        isBootstrapComplete: Bool = false,
        availableModules: [FeaturePluginDescriptor] = []
    ) {
        self.activeSurface = activeSurface
        self.highlightedBadge = highlightedBadge
        self.badgeFeedCount = badgeFeedCount
        self.isBootstrapComplete = isBootstrapComplete
        self.availableModules = availableModules
    }
}

public enum WorkspaceAction: Equatable, Sendable, Action {
    case activate(WorkspaceSurface)
    case recordBadgeHit(String)
    case setBootstrapComplete(Bool)
    case setAvailableModules([FeaturePluginDescriptor])
}

public let workspaceReducer: Reducer<WorkspaceState, WorkspaceAction> = { state, action in
    switch action {
    case let .activate(surface):
        state.activeSurface = surface

    case let .recordBadgeHit(badge):
        state.highlightedBadge = badge
        state.badgeFeedCount += 1

    case let .setBootstrapComplete(isComplete):
        state.isBootstrapComplete = isComplete

    case let .setAvailableModules(modules):
        state.availableModules = modules
    }
}
