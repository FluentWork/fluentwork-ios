import FluentWorkCore
import FluentWorkFeatureFlags

/// 屏 12 里那些**只有一行字**的行（内容一行、说明一行）。
public struct SettingsInfoRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// 说明。稿子 屏 12 的每一行都带一句「这是干什么的」。
    public var detail: String?
    /// 有 `destination` 的行是可以点进去的（稿子在行尾画了 `›`）。
    public var hasDisclosure: Bool
    /// 行首图标。稿子 屏 12 的 `[sr-ico]` 六行都有，而且**全是已有的图标令牌**
    /// （`i-talk` / `i-wave` / `i-mic` / `i-info` / `i-shield` / `i-trash`）——
    /// 所以它不是新资源，是我第一版漏掉的一处形态。
    public var icon: DesignTokens.Icon?

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        hasDisclosure: Bool = false,
        icon: DesignTokens.Icon? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.hasDisclosure = hasDisclosure
        self.icon = icon
    }
}

/// 「删除我的全部素材」这一行的全部可呈现状态。
///
/// 它是**一条不可逆操作**的界面，所以确认文案和回执文案都住在这儿、也就都能被判据钉住：
/// 把「不能撤销」写漏、把级联删除说成只删素材，都是那种在稿子上看不出来、
/// 只有出事之后才发现的错。
public struct SettingsDeleteFlow: Equatable, Sendable {
    /// 请求在飞。**这段时间里那一行不可点**（重复发两次会让幂等回包看起来像没生效）。
    public var isDeleting: Bool
    public var confirmationTitle: String
    public var confirmationMessage: String
    public var confirmButtonTitle: String
    public var cancelButtonTitle: String
    /// 删完之后的服务端回执（用真实的级联计数说话）。没删过就是 `nil`。
    public var resultMessage: String?
    public var errorMessage: String?

    /// 还能不能点。飞行中不能；删过之后还能（再点一次会拿到幂等回包，屏幕上说「已经不在了」）。
    public var canDelete: Bool { !isDeleting }

    public init(
        isDeleting: Bool = false,
        confirmationTitle: String,
        confirmationMessage: String,
        confirmButtonTitle: String,
        cancelButtonTitle: String,
        resultMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.isDeleting = isDeleting
        self.confirmationTitle = confirmationTitle
        self.confirmationMessage = confirmationMessage
        self.confirmButtonTitle = confirmButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
        self.resultMessage = resultMessage
        self.errorMessage = errorMessage
    }
}

extension SettingsViewModel {

    /// 屏 12 的几组（稿子：账号 / 语音偏好 / 通知 / 隐私与数据）。
    ///
    /// **只摆今天真的成立的那些行**：通知三项背后没有任何推送基础设施，账号背后没有登录链路
    /// （iOS 只有游客身份），AI 语速要动音频链路（另一条票）。与其摆一排点了没反应的开关，
    /// 不如让它们先不出现 —— 哪些行没做、为什么，写在 `docs/design/ui-rebuild-plan.md` §7
    /// 与走查清单里。
    public struct SceneRows: Equatable, Sendable {
        public var account: SettingsInfoRow
        public var voice: [SettingsInfoRow]
        public var privacy: [SettingsInfoRow]
        public var deleteFlow: SettingsDeleteFlow

        public init(
            account: SettingsInfoRow,
            voice: [SettingsInfoRow],
            privacy: [SettingsInfoRow],
            deleteFlow: SettingsDeleteFlow
        ) {
            self.account = account
            self.voice = voice
            self.privacy = privacy
            self.deleteFlow = deleteFlow
        }
    }

    public static func sceneRows(from accountData: AccountDataState) -> SceneRows {
        SceneRows(
            account: SettingsInfoRow(
                id: "account.phone",
                title: "手机号",
                // 今天只有游客身份，也没有任何登录 UI。写「未绑定」是实话；
                // 编一个号码或者摆一个点了没反应的「换绑」，是这一屏最不该做的事。
                detail: "未绑定 · 现在用的是游客身份",
                hasDisclosure: false,
                icon: .talk
            ),
            voice: [
                SettingsInfoRow(
                    id: "voice.timbre",
                    title: "音色",
                    // 稿子原文就是这个括号。其余音色随 V1.1，所以这一行不是「没做完」，是「还没到」。
                    detail: "默认音色（其余音色随 V1.1）",
                    hasDisclosure: true,
                    icon: .mic
                )
            ],
            privacy: [
                SettingsInfoRow(
                    id: "privacy.purpose",
                    title: "数据用途说明",
                    detail: "素材与录音不用于训练",
                    hasDisclosure: true,
                    icon: .shield
                ),
                SettingsInfoRow(
                    id: "privacy.delete",
                    title: "删除我的全部素材",
                    // 稿子：用**待改进色**而不是纯红（与全局色彩纪律一致），
                    // 而且「二次确认后才执行」—— 那一层在 `deleteFlow` 里。
                    detail: "二次确认后即时生效，并级联删除衍生的话术块",
                    hasDisclosure: false,
                    icon: .trash
                )
            ],
            deleteFlow: deleteFlow(from: accountData)
        )
    }

    private static func deleteFlow(from state: AccountDataState) -> SettingsDeleteFlow {
        SettingsDeleteFlow(
            isDeleting: state.phase == .deleting,
            confirmationTitle: "删除我的全部素材？",
            // ⚠️ **确认文案里没有数字，这是有意的。**
            //
            // 稿子要求写出「衍生的 N 个话术块也会一并删除」，而服务端只在**删除的回包里**
            // 给这个 N（`DeleteAccountDataResponse.cascaded`）；客户端自己也数不出来 ——
            // 语料库是按游标分页的（只有 `nextCursor`，没有 total），已加载的那一页
            // 不等于全部。用那一页的条数当 N 会**少报**这次损失的规模，
            // 而少报一个不可逆操作的后果是最不该犯的那类错。所以确认文案说清后果的
            // **结构**（哪些东西会一起消失、不能撤销），真实的数字在删完之后回执里给。
            confirmationMessage: """
                这会删除你的素材、录音、练习记录，以及由它们衍生出来的话术块。

                删除后不可恢复。
                """,
            confirmButtonTitle: "删除",
            cancelButtonTitle: "取消",
            resultMessage: resultMessage(from: state),
            errorMessage: state.errorMessage
        )
    }

    /// 删完之后的回执：**用服务端数出来的真实计数说话**。
    ///
    /// 只翻译认得的表名 —— 不认得的那些**不编中文名**（同场景名那条纪律：
    /// 与其显示一个确定但错的名字，不如不显示）。
    private static func resultMessage(from state: AccountDataState) -> String? {
        guard state.phase == .deleted else { return nil }
        if state.wasAlreadyDeleted {
            return "数据已经不在了（这次没有删任何东西）。"
        }
        let parts = cascadeLabels.compactMap { table, label -> String? in
            guard let count = state.cascadeCounts[table], count > 0 else { return nil }
            return "\(label) \(count) 条"
        }
        guard !parts.isEmpty else { return "已经删掉了。" }
        return "已经删掉：" + parts.joined(separator: "、") + "。"
    }

    /// 表名 → 中文。**只放认得的**：`cascaded` 是 `[String: Int]`，
    /// 服务端将来加一张表，这里就不认识它 —— 那时不显示，而不是把表名端到屏幕上。
    private static let cascadeLabels: [(String, String)] = [
        ("phrase_blocks", "话术块"),
        ("practice_sessions", "练习记录"),
        ("materials", "素材"),
        ("drill_records", "闪测记录"),
    ]
}

extension SettingsViewModel {
    /// State → the settings screen's plain model.
    ///
    /// Shows the **effective** value next to whether it came from an override, because those are the
    /// two things a device run needs to tell apart: a flag turned on by a local override behaves
    /// exactly like one that is on by default, and only one of them survives a reinstall.
    ///
    /// `appVersion` is a parameter rather than a `Bundle.main` read inside: the bundle is an app-layer
    /// fact (in a test process it is the test runner's bundle, so a projection that read it would
    /// print the wrong version in exactly the place you want to check the right one). The `"—"`
    /// fallback stays here because it is a **display** decision — "the version line is never blank".
    public static func make(
        from state: FeatureFlagsState,
        appVersion: String?,
        accountData: AccountDataState = AccountDataState()
    ) -> SettingsViewModel {
        let flags = AppFeatureFlag.allCases.map { flag in
            SettingsViewModel.FlagRow(
                id: flag.rawValue,
                title: flag.rawValue,
                isEnabled: state.isEnabled(flag),
                isOverridden: state.localOverrides[flag] != nil
            )
        }
        return SettingsViewModel(
            flags: flags,
            appVersion: appVersion ?? "—",
            hasOverrides: !state.localOverrides.isEmpty,
            sceneRows: sceneRows(from: accountData)
        )
    }
}
