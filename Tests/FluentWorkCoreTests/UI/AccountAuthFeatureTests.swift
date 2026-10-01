import FluentWorkCore
import Testing

/// 账号密码那张表单的规则（屏 12 的账号链路）。
///
/// 这一组判据盯的是**三件会真的出事的事**：重复建号、把人家敲的字擦掉、以及
/// 让「邮箱不存在」与「口令不对」在客户端重新长出差别。
@Suite("账号表单")
struct AccountAuthFeatureTests {

    private func state(_ phase: AccountAuthPhase = .idle) -> AccountAuthState {
        AccountAuthState(phase: phase, mode: .login, email: "tango@example.com", password: "pw")
    }

    // MARK: - 不能重复提交

    /// 飞行中再点一次**什么都不该发生**。
    ///
    /// 这条挡的是重复建号：注册那条路跑两遍，第二遍要么撞 409，
    /// 要么（两次都在飞时）因为「查不到」而各建一个号。
    @Test func 飞行中不能重复提交() {
        var submitting = state(.submitting)
        accountAuthReducer(&submitting, .submitTapped)
        #expect(submitting.phase == .submitting)
    }

    /// 空邮箱或空口令不能提交。
    @Test func 空输入不能提交() {
        var empty = AccountAuthState(mode: .login, email: "   ", password: "pw")
        accountAuthReducer(&empty, .submitTapped)
        #expect(empty.phase == .idle)

        var noPassword = AccountAuthState(mode: .login, email: "tango@example.com", password: "")
        accountAuthReducer(&noPassword, .submitTapped)
        #expect(noPassword.phase == .idle)
    }

    /// **没提交过不可能成功** —— 没请求却进了 `.signedIn`，说明有人跳过了那一步。
    @Test func 没提交过不会成功() {
        var idle = state()
        accountAuthReducer(&idle, .succeeded)
        #expect(idle.phase == .idle, "没提交却进了已登录")
    }

    // MARK: - 失败不清空输入

    /// 失败之后**邮箱与口令都还在**。
    ///
    /// 这不是体贴，是正确性：手机上重敲一遍邮箱的代价足以让人放弃这次登录，
    /// 而这只是因为他打错了一个字母。
    @Test func 失败之后输入还在() {
        var state = state(.submitting)
        accountAuthReducer(&state, .failed(accountAuthRejectedMessage))

        #expect(state.phase == .failed)
        #expect(state.email == "tango@example.com")
        #expect(state.password == "pw")
        #expect(state.errorMessage == accountAuthRejectedMessage)
    }

    /// 改了输入，上一次的失败就收起来。
    /// 那句话说的是**上一次**提交，留着会让人以为现在这行字也有问题。
    @Test func 改输入会收起上一次的失败() {
        var state = state(.failed)
        accountAuthReducer(&state, .emailChanged("tango2@example.com"))
        #expect(state.errorMessage == nil)
        #expect(state.phase == .idle)
    }

    // MARK: - 两种失败在客户端也不长出差别

    /// 客户端**不分辨**「邮箱不存在」与「口令不对」：文案只有一句。
    @Test func 凭据失败只有一句话() {
        #expect(accountAuthRejectedMessage == "邮箱或密码不对")
    }

    /// 换模式时把上一轮的失败清掉（否则切到注册还挂着「邮箱或密码不对」）。
    @Test func 换模式清掉上一轮的失败() {
        var state = state(.failed)
        accountAuthReducer(&state, .modeChanged(.register))
        #expect(state.mode == .register)
        #expect(state.errorMessage == nil)
    }

    /// 但**飞行中不许换**：切了模式，屏幕上说的和请求里发的就不是一回事了。
    @Test func 飞行中不能换模式() {
        var state = state(.submitting)
        accountAuthReducer(&state, .modeChanged(.register))
        #expect(state.mode == .login)
    }

    // MARK: - 成功之后口令不留在状态里

    /// 登录成功后**口令必须从状态里消失**。
    ///
    /// 它是这个 state 里唯一不该继续活着的东西：之后任何一次状态快照、日志、
    /// 或者别的模块顺手读一眼，都不该能拿到它。
    @Test func 成功之后清掉口令() {
        var state = state(.submitting)
        accountAuthReducer(&state, .succeeded)

        #expect(state.phase == .signedIn)
        #expect(state.password.isEmpty, "口令留在了状态里")
        #expect(state.email == "tango@example.com", "邮箱该留着（屏幕上还要显示是谁登进来了）")
    }
}
