import Foundation
import FluentWorkNetworking
import TGReduxKit

/// 「删除我的全部素材」这条不可逆操作的相位（稿子 屏 12 的「隐私与数据」）。
///
/// 它为什么值得一个独立 feature 而不是设置页里的三个 `@State`：
/// **这是一条会删数据的路**，而它的每一步都得能被判据钉住 ——
/// 「没有弹过确认就不许开始删」这条规则写在视图里，等于没有规则。
public enum AccountDataPhase: Equatable, Sendable {
    case idle
    /// 二次确认已经给学员看了，等他按「确定」。
    case confirming
    /// 请求在飞。**这段时间里按钮必须不可点** —— 不可逆的操作重复发两次，
    /// 第二次的幂等回包会让人以为「没生效」而再点一次。
    case deleting
    case deleted
    case failed
}

public struct AccountDataState: Equatable, Sendable, State {
    public var phase: AccountDataPhase
    /// 删完之后服务端数出来的级联计数（表名 → 行数）。
    ///
    /// ⚠️ **它只有删完之后才有**。稿子要求确认文案写出「衍生的 N 个话术块也会一并删除」，
    /// 而服务端只在**删除的回包里**给这个 N（`DeleteAccountDataResponse.cascaded`）。
    /// 客户端自己也数不出来：语料库是游标分页的（只有 `nextCursor`，没有 total），
    /// 已加载的那一页不等于全部 —— 拿它当 N 会**少报**这次损失的规模，
    /// 而少报一个不可逆操作的后果是最不该犯的那类错。所以确认文案只说清后果的**结构**，
    /// 真实的数字在删完之后回执里给。见 `docs/design/ui-walkthrough/` 的屏 12。
    public var cascadeCounts: [String: Int]
    /// 服务端说「本来就已经删过了」（幂等）。屏幕上说「数据已经不在了」，**不报错**。
    public var wasAlreadyDeleted: Bool
    public var errorMessage: String?

    public init(
        phase: AccountDataPhase = .idle,
        cascadeCounts: [String: Int] = [:],
        wasAlreadyDeleted: Bool = false,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.cascadeCounts = cascadeCounts
        self.wasAlreadyDeleted = wasAlreadyDeleted
        self.errorMessage = errorMessage
    }
}

public enum AccountDataAction: Equatable, Sendable, Action {
    /// 屏幕上按下「删除我的全部素材」——**只是把确认摆出来**，不删任何东西。
    case deleteTapped
    case confirmationCancelled
    /// 二次确认里的「确定」。
    case confirmed
    case deleteSucceeded(DeleteAccountDataResponse)
    case deleteFailed(String)
}

public let accountDataReducer: Reducer<AccountDataState, AccountDataAction> = { state, action in
    switch action {
    case .deleteTapped:
        // 已经在删 / 已经删过，就不再摆一次确认 —— 那会让人以为「上一次没生效」。
        guard state.phase == .idle || state.phase == .failed else { return }
        state.phase = .confirming
        state.errorMessage = nil

    case .confirmationCancelled:
        guard state.phase == .confirming else { return }
        state.phase = .idle

    case .confirmed:
        // **只有走过确认才允许开始删。** 这条挡的是「确认被漏掉」：
        // 视图上一个手滑的直接调用、或者将来有人把 `.deleteTapped` 直接接到请求上，
        // 都会在这里被挡住（相位不是 `.confirming` 就什么都不发生）。
        guard state.phase == .confirming else { return }
        state.phase = .deleting

    case let .deleteSucceeded(response):
        state.phase = .deleted
        state.cascadeCounts = response.cascaded
        state.wasAlreadyDeleted = response.alreadyDeleted
        state.errorMessage = nil

    case let .deleteFailed(message):
        state.phase = .failed
        state.errorMessage = message
    }
}
