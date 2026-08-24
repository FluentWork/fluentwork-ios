import FluentWorkFeatureFlags
import Foundation

public struct FeaturePluginDescriptor: Equatable, Sendable, Identifiable {
    public let feature: AppFeatureFlag
    public let moduleName: String
    public let entryRoute: String

    public var id: String {
        moduleName
    }

    public init(
        feature: AppFeatureFlag,
        moduleName: String,
        entryRoute: String
    ) {
        self.feature = feature
        self.moduleName = moduleName
        self.entryRoute = entryRoute
    }
}

public protocol FeaturePluginRegistryProtocol: Sendable {
    func allPlugins() -> [FeaturePluginDescriptor]
    func enabledPlugins(for snapshot: FeatureFlagSnapshot) -> [FeaturePluginDescriptor]
}

public struct StaticFeaturePluginRegistry: FeaturePluginRegistryProtocol {
    public let plugins: [FeaturePluginDescriptor]

    public init(plugins: [FeaturePluginDescriptor] = FeaturePluginCatalog.firstWave) {
        self.plugins = plugins
    }

    public func allPlugins() -> [FeaturePluginDescriptor] {
        plugins
    }

    public func enabledPlugins(for snapshot: FeatureFlagSnapshot) -> [FeaturePluginDescriptor] {
        plugins.filter { snapshot.isEnabled($0.feature) }
    }
}

public enum FeaturePluginCatalog {
    public static let firstWave: [FeaturePluginDescriptor] = [
        FeaturePluginDescriptor(
            feature: .speakingRoom,
            moduleName: "SpeakingRoom",
            entryRoute: "/speaking-room"
        ),
        FeaturePluginDescriptor(
            feature: .workspaceReview,
            moduleName: "Review",
            entryRoute: "/review"
        ),
        FeaturePluginDescriptor(
            feature: .dailyRead,
            moduleName: "DailyRead",
            entryRoute: "/daily-read"
        ),
        FeaturePluginDescriptor(
            feature: .drill,
            moduleName: "Drill",
            entryRoute: "/drill"
        ),
    ]
}
