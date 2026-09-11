import TGFeatureFlag
import TGReduxKit

public enum AppFeatureFlag: String, CaseIterable, Codable, Hashable, Sendable, FeatureFlagKey {
    case speakingRoom
    case workspaceReview
    case degradedTextMode
    case dailyRead
    case drill
    case corpus
    case topicSuggestions
    case pronunciationReview
    /// When enabled, speaking-room turns start/stop from VAD energy.
    /// Default off: tap-to-talk is the primary path (I20 Item 4).
    case voiceVadAuto
    /// Engine-level voice processing on the capture input — echo cancellation
    /// plus noise suppression and AGC, via
    /// `AVAudioInputNode.setVoiceProcessingEnabled(_:)`.
    ///
    /// This is a *different switch* from the session-level `.playAndRecord` +
    /// `.voiceChat` set by `DefaultAudioSessionManager`. That one configures
    /// the audio session; on a self-built `AVAudioEngine` graph it does not by
    /// itself put the processed stream into the graph, which is why the
    /// engine-level call is the one that decides. See meta `77_` §3.2.
    ///
    /// Default off, and deliberately absent from `firstWave`. Enabling voice
    /// processing changes the input node's format (it can come back
    /// multi-channel, with echo-reference channels alongside the real mic) and
    /// puts the output node into voice-processing mode as well. Neither has
    /// been confirmed on a device, and the failure mode it exists to remove —
    /// the assistant hearing itself — is the one thing a stale default would
    /// keep. Flip it only after `ios docs/62` T4 passes.
    case voiceProcessing

    public var defaultValue: FeatureFlagValue {
        .bool(false)
    }

    public var description: String {
        rawValue
    }
}

/// Domain snapshot used by Redux `FeatureFlagsState` (Store is SoT).
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
            .dailyRead,
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

/// Maps a cold TGFeatureFlag snapshot into the Redux domain snapshot.
public enum FeatureFlagSnapshotMapper {
    public static func map(_ remote: TGFeatureFlag.FeatureFlagSnapshot) -> FeatureFlagSnapshot {
        var enabledFlags = Set<AppFeatureFlag>()
        for flag in AppFeatureFlag.allCases where remote.isEnabled(flag) {
            enabledFlags.insert(flag)
        }
        return FeatureFlagSnapshot(enabledFlags: enabledFlags)
    }
}

/// Builds a resolver seeded with first-wave local defaults (Debug can override later).
public enum FeatureFlagResolverFactory {
    public static func makeFirstWaveResolver() -> FeatureFlagResolver {
        let resolver = FeatureFlagResolver()
        let enabled = FeatureFlagSnapshot.firstWave.enabledFlags.map { $0 as any FeatureFlagKey }
        resolver.register(provider: DebugProvider(), priority: .highest)
        resolver.register(
            provider: LocalProvider(enabledFeatures: enabled),
            priority: .lowest
        )
        return resolver
    }
}
