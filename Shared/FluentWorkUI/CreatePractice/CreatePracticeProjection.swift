import FluentWorkCore
import Foundation

/// 创建练习弹层的呈现数据（09-26 稿 屏 11）。
///
/// 规则**不在这里**：`canSubmit` / `hasEnoughDraft` / `isOverLimit` 都住在
/// `CreatePracticeState` 上，这一层只把它们翻成人看得懂的形状与句子。
/// 这里唯一新增的判断是「同一件事该说哪句话」——那是呈现，不是规则。
public struct CreatePracticeViewModel: Equatable, Sendable {
    public struct InputOption: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var isSelected: Bool

        public init(id: String, title: String, isSelected: Bool) {
            self.id = id
            self.title = title
            self.isSelected = isSelected
        }
    }

    public struct LengthOption: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// 回合数与时长。**两个选项都必须有这一行**：稿子要求两者并列呈现、
        /// 不做视觉降级 —— 缺了它，迷你看起来就像个「简化版」。
        public var detail: String
        public var isSelected: Bool

        public init(id: String, title: String, detail: String, isSelected: Bool) {
            self.id = id
            self.title = title
            self.detail = detail
            self.isSelected = isSelected
        }
    }

    public var title: String
    public var inputs: [InputOption]
    public var selectedInput: CreatePracticeInput

    // MARK: 素材输入

    /// 文本输入两种模式共用同一个输入框，只是问法不同。
    public var draftLabel: String
    public var draftPlaceholder: String
    /// 学员已经写下的那份草稿（输入框绑它）。
    public var draft: String
    /// 预置场景那一路不显示输入框。
    public var showsDraftField: Bool
    public var presetSceneTitle: String
    public var characterCount: Int
    public var characterLimit: Int
    /// 超限时的那句话（含超出多少）；没超限是 `nil`。
    public var overLimitMessage: String?
    /// 文本还没写够时的那句话（含还差多少）；够了或不需要文本时是 `nil`。
    public var shortfallMessage: String?

    // MARK: 隐私与时长

    /// 常驻的隐私声明（稿子 A4：常驻，不是折叠在角落的一次性弹窗）。
    public var privacyNotice: String
    public var lengthSectionTitle: String
    public var lengthOptions: [LengthOption]

    // MARK: 提交

    public var canSubmit: Bool
    public var submitTitle: String
    public var isSubmitting: Bool
    public var errorMessage: String?

    public init(
        title: String,
        inputs: [InputOption],
        selectedInput: CreatePracticeInput,
        draftLabel: String,
        draftPlaceholder: String,
        draft: String,
        showsDraftField: Bool,
        presetSceneTitle: String,
        characterCount: Int,
        characterLimit: Int,
        overLimitMessage: String?,
        shortfallMessage: String?,
        privacyNotice: String,
        lengthSectionTitle: String,
        lengthOptions: [LengthOption],
        canSubmit: Bool,
        submitTitle: String,
        isSubmitting: Bool,
        errorMessage: String?
    ) {
        self.title = title
        self.inputs = inputs
        self.selectedInput = selectedInput
        self.draftLabel = draftLabel
        self.draftPlaceholder = draftPlaceholder
        self.draft = draft
        self.showsDraftField = showsDraftField
        self.presetSceneTitle = presetSceneTitle
        self.characterCount = characterCount
        self.characterLimit = characterLimit
        self.overLimitMessage = overLimitMessage
        self.shortfallMessage = shortfallMessage
        self.privacyNotice = privacyNotice
        self.lengthSectionTitle = lengthSectionTitle
        self.lengthOptions = lengthOptions
        self.canSubmit = canSubmit
        self.submitTitle = submitTitle
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
    }
}

extension CreatePracticeViewModel {
    public static func make(from state: CreatePracticeState) -> CreatePracticeViewModel {
        CreatePracticeViewModel(
            title: "开始新练习",
            inputs: CreatePracticeInput.allCases.map { input in
                InputOption(
                    id: input.rawValue,
                    title: title(for: input),
                    isSelected: input == state.input
                )
            },
            selectedInput: state.input,
            draftLabel: draftLabel(for: state.input),
            draftPlaceholder: draftPlaceholder(for: state.input),
            draft: state.draft,
            showsDraftField: state.needsDraft,
            presetSceneTitle: presetSceneTitle(for: state.presetScene),
            characterCount: state.characterCount,
            characterLimit: CreatePracticeState.draftCharacterLimit,
            overLimitMessage: overLimitMessage(for: state),
            // 不需要文本的那一路不该显示「还差 N 字」—— 那句话会让人以为漏填了什么。
            shortfallMessage: state.needsDraft && !state.hasEnoughDraft && !state.isOverLimit
                ? shortfallMessage(for: state)
                : nil,
            privacyNotice: privacyNotice,
            lengthSectionTitle: "会话时长",
            lengthOptions: PracticeSessionLength.allCases.map { length in
                LengthOption(
                    id: length.rawValue,
                    title: lengthTitle(for: length),
                    detail: lengthDetail(for: length),
                    isSelected: length == state.length
                )
            },
            canSubmit: state.canSubmit,
            submitTitle: state.isSubmitting ? "正在准备…" : "开始练习",
            isSubmitting: state.isSubmitting,
            errorMessage: state.errorMessage
        )
    }

    /// 稿子 A4：这句话是**常驻**的，不是打开弹层时弹一次的说明。
    ///
    /// 措辞照抄稿子 —— 它是一句承诺，改一个字都是改承诺。
    public static let privacyNotice = "素材仅用于生成练习，不用于训练"

    private static func title(for input: CreatePracticeInput) -> String {
        switch input {
        case .sentence:
            return "一句话描述"
        case .paste:
            return "粘贴素材"
        case .preset:
            return "预置场景"
        }
    }

    private static func draftLabel(for input: CreatePracticeInput) -> String {
        switch input {
        case .sentence:
            return "今天想练什么？"
        case .paste, .preset:
            return "粘贴一段材料"
        }
    }

    private static func draftPlaceholder(for input: CreatePracticeInput) -> String {
        switch input {
        case .sentence:
            return "一句话说清要练的事，场景设定由 AI 补全"
        case .paste, .preset:
            return "把会议纪要、邮件或文档片段粘进来"
        }
    }

    /// MVP 只有一个预置场景，所以这里是一张**单行的表**而不是一个枚举的映射 ——
    /// 加第二个场景时，改的是这一处和 `CreatePracticeState` 里那个常量。
    private static func presetSceneTitle(for scene: String) -> String {
        scene == CreatePracticeState.dailyStandupScene ? "Daily Standup" : scene
    }

    private static func lengthTitle(for length: PracticeSessionLength) -> String {
        switch length {
        case .standard:
            return "标准"
        case .mini:
            return "迷你"
        }
    }

    private static func lengthDetail(for length: PracticeSessionLength) -> String {
        switch length {
        case .standard:
            return "8–12 回合 · 约 15 分钟"
        case .mini:
            return "3–5 回合 · 约 2 分钟"
        }
    }

    private static func overLimitMessage(for state: CreatePracticeState) -> String? {
        guard state.isOverLimit else { return nil }
        return "超出 \(state.characterCount - CreatePracticeState.draftCharacterLimit) 字，删掉一些再开始"
    }

    private static func shortfallMessage(for state: CreatePracticeState) -> String? {
        let missing = CreatePracticeState.minimumDraftCharacters - state.characterCount
        return "还差 \(missing) 字就能开始"
    }
}
