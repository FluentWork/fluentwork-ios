import FluentWorkCore
import SwiftUI

/// 屏 15 的投影（稿子 `#scr15`）。
///
/// 三处**这一屏独有的规矩**都住在这里，因为它们都是「说错就出事」的话：
/// 1. 错误行是**表单级**的，不是字段级的（挂到邮箱上等于说「邮箱错了」）；
/// 2. 预留的两条入口要**明确写清为什么不能点**（可点却无反应 = 教用户「这里有坏按钮」）；
/// 3. 合并说明要说「不会丢」（那是学员在这一屏唯一真正担心的事）。
public struct LoginViewModel: Equatable, Sendable {
    /// 一条**还没开放**的登录方式。`reason` 不是装饰：没有它，禁用就变成「点了没反应」。
    public struct ReservedMethod: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public var title: String
    public var subtitle: String
    public var modes: [(title: String, mode: AccountAuthMode)] = []
    public var selectedMode: AccountAuthMode
    public var email: String
    public var password: String
    public var errorMessage: String?
    public var submitTitle: String
    public var canSubmit: Bool
    public var isInFlight: Bool
    public var reservedMethods: [ReservedMethod]
    public var reservedReason: String
    public var mergeNote: String
    public var privacyNote: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.modes.map(\.title) == rhs.modes.map(\.title)
            && lhs.selectedMode == rhs.selectedMode
            && lhs.email == rhs.email && lhs.password == rhs.password
            && lhs.errorMessage == rhs.errorMessage
            && lhs.submitTitle == rhs.submitTitle
            && lhs.canSubmit == rhs.canSubmit && lhs.isInFlight == rhs.isInFlight
            && lhs.reservedMethods == rhs.reservedMethods
            && lhs.reservedReason == rhs.reservedReason
            && lhs.mergeNote == rhs.mergeNote && lhs.privacyNote == rhs.privacyNote
    }
}

extension LoginViewModel {
    public static func make(from state: AccountAuthState) -> LoginViewModel {
        LoginViewModel(
            // 与 屏 04 的 G4 措辞同源：注册的触发点是「我攒下的东西要属于我」。
            title: "登录后，你的记录才真正属于你",
            subtitle: "换设备、重装 App 都不会丢",
            modes: [(title: "登录", mode: .login), (title: "注册", mode: .register)],
            selectedMode: state.mode,
            email: state.email,
            password: state.password,
            errorMessage: state.errorMessage,
            submitTitle: submitTitle(for: state),
            canSubmit: state.canSubmit,
            isInFlight: state.isInFlight,
            reservedMethods: [
                ReservedMethod(id: "sms", title: "短信登录"),
                ReservedMethod(id: "wechat", title: "微信登录"),
            ],
            reservedReason: "这两条随 V1.1 开放，现在还不能点。",
            // 「不会丢」是这一屏唯一真正要安顿的担心 —— 稿子原话。
            mergeNote: "登录后，本机已有的练习记录和话术块会自动并进这个账号——不会丢，也不用你手动搬。",
            privacyNote: "邮箱仅用于登录。素材与录音不用于训练，随时可以在设置页一键删除。"
        )
    }

    /// 提交中要换文案：**转圈不够** —— 得说出正在做什么。
    /// 注册与登录是两件事（一个在建账号，一个在进已有账号），所以进行中也分两句。
    private static func submitTitle(for state: AccountAuthState) -> String {
        switch (state.phase, state.mode) {
        case (.submitting, .register): return "正在创建账号…"
        case (.submitting, .login): return "正在登录…"
        case (_, .register): return "注册"
        case (_, .login): return "登录"
        }
    }
}

/// 屏 15 · 登录 / 注册。
///
/// **全屏页**（稿子 §03：它与说的房间/回顾/设置同属「全屏页（从入口推入）」），
/// 所以自己带 `.fullScreenPage()`。
public struct LoginView: View {
    private let model: LoginViewModel
    private let onModeChanged: (AccountAuthMode) -> Void
    private let onEmailChanged: (String) -> Void
    private let onPasswordChanged: (String) -> Void
    private let onSubmit: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    public init(
        model: LoginViewModel,
        onModeChanged: @escaping (AccountAuthMode) -> Void = { _ in },
        onEmailChanged: @escaping (String) -> Void = { _ in },
        onPasswordChanged: @escaping (String) -> Void = { _ in },
        onSubmit: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onModeChanged = onModeChanged
        self.onEmailChanged = onEmailChanged
        self.onPasswordChanged = onPasswordChanged
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s6) {
                header
                modeSegments
                fields
                submitButton
                reservedSection
                notesCard
            }
            .padding(.horizontal, DesignTokens.Spacing.pageMargin)
            .padding(.vertical, DesignTokens.Spacing.s4)
        }
        .background(DesignTokens.Color.background)
        .fullScreenPage()
        .navigationTitle("登录")
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s1) {
            Text(model.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Text(model.subtitle)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
        }
    }

    /// `seg`：登录 / 注册**并列切换**，不是两页（稿子原话）。
    private var modeSegments: some View {
        HStack(spacing: 3) {
            ForEach(model.modes, id: \.title) { entry in
                Button {
                    onModeChanged(entry.mode)
                } label: {
                    Text(entry.title)
                        .font(DesignTokens.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            entry.mode == model.selectedMode
                                ? DesignTokens.Color.brandStrong
                                : .clear
                        )
                        .foregroundStyle(
                            entry.mode == model.selectedMode
                                ? DesignTokens.Color.textPrimary
                                : DesignTokens.Color.textSecondary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isInFlight)
            }
        }
        .padding(3)
        .background(DesignTokens.Color.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityIdentifier("login.modeSegments")
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
            field("邮箱", text: Binding(
                get: { model.email },
                set: onEmailChanged
            ), isSecure: false, identifier: "login.email")
            field("口令", text: Binding(
                get: { model.password },
                set: onPasswordChanged
            ), isSecure: true, identifier: "login.password")

            // **错误行在表单级，不在字段上。**
            //
            // 稿子（open-design 那一轮）提的判断，比我原来的 brief 更严谨：
            // 把「邮箱或密码不对」挂在邮箱输入框下面，等于在说「是邮箱错了」——
            // 而那正是服务端不肯透露的那件事（透露了就等于送一个账号枚举器）。
            if let message = model.errorMessage {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.improve)
                    .accessibilityIdentifier("login.formError")
            }
        }
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        isSecure: Bool,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s1) {
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            Group {
                if isSecure {
                    SecureField("", text: text)
                } else {
                    // 邮箱框的键盘/大小写/纠错这三条都是 iOS 专有 API，而这个包同时构建
                    // macOS（`swift test` 就跑在 macOS 上），所以必须分平台。
                    #if os(iOS)
                        TextField("", text: text)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    #else
                        TextField("", text: text)
                    #endif
                }
            }
            .font(DesignTokens.Typography.body)
            .foregroundStyle(DesignTokens.Color.textPrimary)
            .padding(.horizontal, DesignTokens.Spacing.s3)
            .padding(.vertical, 12)
            .background(DesignTokens.Color.backgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .accessibilityIdentifier(identifier)
        }
    }

    private var submitButton: some View {
        Button(action: onSubmit) {
            HStack(spacing: DesignTokens.Spacing.s2) {
                if model.isInFlight {
                    ProgressView().progressViewStyle(.circular).tint(DesignTokens.Color.textPrimary)
                }
                Text(model.submitTitle)
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                model.canSubmit ? DesignTokens.Color.brandStrong : DesignTokens.Color.backgroundElevated
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!model.canSubmit)
        .accessibilityIdentifier("login.submit")
    }

    /// 预留的两条：**禁用 ＋ 说清为什么**。
    ///
    /// 稿子写的是「明确禁用 ＋ 注明随 V1.1 开放」。缺了后半句，禁用就变成
    /// 「点了没反应」—— 那等于教用户「这个产品有坏按钮」。
    private var reservedSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
            HStack(spacing: DesignTokens.Spacing.s3) {
                ForEach(model.reservedMethods) { method in
                    Text(method.title)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DesignTokens.Color.backgroundElevated)
                        .clipShape(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                        )
                }
            }
            .opacity(0.55)
            .accessibilityHidden(true)

            Text(model.reservedReason)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .accessibilityIdentifier("login.reservedReason")
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s2) {
            Text(model.mergeNote)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Text(model.privacyNote)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
    }
}
