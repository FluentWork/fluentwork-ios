import TGReduxKit

public enum AppFeatureFlag: String, CaseIterable, Codable, Hashable, Sendable {
    case speakingRoom
    case workspaceReview
    case degradedTextMode
    case dailyRead
    case drill
    case corpus
    case topicSuggestions
    case pronunciationReview
}

public struct FeatureFlagSnapshot: Equatable, Sendable {
    public var enabledFlags: Set<AppFeatureFlag>

    public init(enabledFlags: Set<AppFeatureFlag> = []) {
        self.enabledFlags = enabledFlags
    }

    public func isEnabled(_ flag: AppFeatureFlag) -> Bool {
        enabledFlags.contains(flag)
    }

    public static let empty = FeatureFlagSnapshot()

    public static let firstWave = FeatureFlagSnapshot(
        enabledFlags: [
            .speakingRoom,
            .workspaceReview,
            .degradedTextMode,
        ]
    )
}

public struct FeatureFlagsState: Equatable, Sendable, State {
    public var snapshot: FeatureFlagSnapshot
    public var localOverrides: [AppFeatureFlag: Bool]
    public var isRemoteLoaded: Bool

    public init(
        snapshot: FeatureFlagSnapshot = .empty,
        localOverrides: [AppFeatureFlag: Bool] = [:],
        isRemoteLoaded: Bool = false
    ) {
        self.snapshot = snapshot
        self.localOverrides = localOverrides
        self.isRemoteLoaded = isRemoteLoaded
    }

    public func isEnabled(_ flag: AppFeatureFlag) -> Bool {
        if let override = localOverrides[flag] {
            return override
        }

        return snapshot.isEnabled(flag)
    }

    public var effectiveSnapshot: FeatureFlagSnapshot {
        var enabledFlags = snapshot.enabledFlags

        for (flag, isEnabled) in localOverrides {
            if isEnabled {
                enabledFlags.insert(flag)
            } else {
                enabledFlags.remove(flag)
            }
        }

        return FeatureFlagSnapshot(enabledFlags: enabledFlags)
    }
}

public enum FeatureFlagsAction: Equatable, Sendable, Action {
    case applyRemoteSnapshot(FeatureFlagSnapshot)
    case setLocalOverride(flag: AppFeatureFlag, isEnabled: Bool)
    case clearLocalOverrides
}

public let featureFlagsReducer: Reducer<FeatureFlagsState, FeatureFlagsAction> = { state, action in
    switch action {
    case let .applyRemoteSnapshot(snapshot):
        state.snapshot = snapshot
        state.isRemoteLoaded = true

    case let .setLocalOverride(flag, isEnabled):
        state.localOverrides[flag] = isEnabled

    case .clearLocalOverrides:
        state.localOverrides.removeAll()
    }
}
