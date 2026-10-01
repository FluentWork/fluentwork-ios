import FluentWorkPluginSupport
import TGReduxKit

public enum WorkspaceSurface: String, Equatable, Sendable {
    case workbench
    case speakingRoom
    case review
}

/// 工作台那一格状态。
///
/// ⚠️ **它没有自己的 action 族，这不是漏写，是刻意的。**
///
/// 这五个字段全部是**派生值**：`isBootstrapComplete` / `activeSurface` / `availableModules`
/// 由启动结果与功能开关算出来，`highlightedBadge` / `badgeFeedCount` 由会话里的命中镜像过来。
/// 派生的地方是 `appCrossCuttingReducer`（跨切片派生正是它存在的理由），而 reducer 里**发不出**
/// 副作用，所以「用 action 再写一遍」这条路只能得到一份没人派发的孪生代码 ——
/// 它们此前确实存在（`WorkspaceAction` 四条），长着一副「有东西在派我」的样子，而一条都没被派过。
///
/// 同理，`WorkspaceState` 也没有「重置」动作：换账号时的清理在 `appCrossCuttingReducer` 里
/// 对 corpus / sessionHistory 做，工作台这几个值不需要清。
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
