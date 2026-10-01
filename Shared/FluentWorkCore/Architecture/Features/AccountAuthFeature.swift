import Foundation
import FluentWorkNetworking
import TGReduxKit

/// 账号密码登录这条路上的两种意图。
///
/// 它们共用同一张表单（邮箱 ＋ 口令），所以放在一个 state 里用 mode 区分 ——
/// 分成两个 feature 会让「输入框里那行字」有两个去处，而学员在切换时看到的应该还是同一张表。
public enum AccountAuthMode: Equatable, Sendable {
    case login
    case register
}

/// 表单相位。
///
/// `.awaitingMerge` 是**单独一档**而不是并进 `.submitting`：这两段时间屏幕上该说的话不一样 ——
/// 前者是「正在登录」，后者是「你的记录正在并进这个账号」。而后者正是学员最怕丢东西的那一刻。
public enum AccountAuthPhase: Equatable, Sendable {
    case idle
    case submitting
    case awaitingMerge
    case signedIn
    case failed
}

public struct AccountAuthState: Equatable, Sendable, State {
    public var phase: AccountAuthPhase
    public var mode: AccountAuthMode
    public var email: String
    public var password: String
    public var errorMessage: String?

    /// 飞行中的两个相位都不可再提交。
    ///
    /// **这条挡的不是体验，是重复建号**：`.submitTapped` 打两次，注册那条路会跑两遍 ——
    /// 第二遍要么撞 409，要么（更糟）在两次都在飞时因为「查不到」而各建一个号。
    public var isInFlight: Bool { phase == .submitting || phase == .awaitingMerge }

    /// 非空即可提交。格式与强度**不由客户端裁决** —— 服务端才是权威，
    /// 而客户端抢先报「邮箱格式不对」会在服务端规则变化时变成一句假话。
    public var canSubmit: Bool {
        !isInFlight && !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    public init(
        phase: AccountAuthPhase = .idle,
        mode: AccountAuthMode = .login,
        email: String = "",
        password: String = "",
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.mode = mode
        self.email = email
        self.password = password
        self.errorMessage = errorMessage
    }
}

public enum AccountAuthAction: Equatable, Sendable, Action {
    case modeChanged(AccountAuthMode)
    case emailChanged(String)
    case passwordChanged(String)
    /// 屏幕上按下「登录」/「注册」。**只把请求排上**，真正的调用在中间件里。
    case submitTapped
    /// 凭据过了，接下来要把本机游客的记录并进这个账号。
    case credentialAccepted
    case succeeded
    case failed(String)
}

/// 两种凭据失败的**同一句话**。
///
/// 服务端有意不区分「邮箱不存在」与「口令不对」（区分等于送一个免费的账号枚举器），
/// 客户端**也不区分** —— 连文案都不该透出差别，否则这份差别会从别处漏回来。
public let accountAuthRejectedMessage = "邮箱或密码不对"

public let accountAuthReducer: Reducer<AccountAuthState, AccountAuthAction> = { state, action in
    switch action {
    case let .modeChanged(mode):
        guard !state.isInFlight else { return }
        state.mode = mode
        state.errorMessage = nil

    case let .emailChanged(email):
        state.email = email
        // 改了输入就把上一次的失败收起来：那句话说的是**上一次**提交，留着会让人以为
        // 现在这行字也有问题。
        if state.phase == .failed {
            state.phase = .idle
            state.errorMessage = nil
        }

    case let .passwordChanged(password):
        state.password = password
        if state.phase == .failed {
            state.phase = .idle
            state.errorMessage = nil
        }

    case .submitTapped:
        guard state.canSubmit else { return }
        state.phase = .submitting
        state.errorMessage = nil

    case .credentialAccepted:
        // 只有真的提交过才可能被接受。
        guard state.phase == .submitting else { return }
        state.phase = .awaitingMerge

    case .succeeded:
        guard state.isInFlight || state.phase == .signedIn else { return }
        state.phase = .signedIn
        state.errorMessage = nil
        // **口令不留在状态里**。它是这个 state 里唯一不该被留下继续活着的东西 ——
        // 登录已经成功，之后任何一次状态快照/日志都不需要它。
        state.password = ""

    case let .failed(message):
        state.phase = .failed
        state.errorMessage = message
        // 邮箱**保留**（人会想改一个字母再试），口令**保留**（否则每次重试都要重敲，
        // 而这在手机上尤其烦）。失败不等于「把人家刚写的东西擦掉」。
    }
}
