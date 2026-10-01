import Foundation
import TGReduxKit

/// 「今天练什么」的三种给法（09-26 稿 屏 11）。
///
/// 三者不是三种界面，是**同一次创建的三种素材来源**：一句话描述、粘贴一段材料、
/// 或者直接用预置场景。服务端侧它们的差别只体现在 `POST /materials` 的 `kind` 上
/// （`sentence` / `paste`），预置场景则**不建素材**，直接开会话。
public enum CreatePracticeInput: String, CaseIterable, Equatable, Sendable {
    case sentence
    case paste
    case preset
}

/// 会话时长（PRD B1 / V1.6 新增）。
///
/// **迷你不是「简化版」**：稿子 §屏 11 写着两个选项并列呈现、不做视觉降级，
/// 因为目标用户碎片时间多，只认标准会话会把北极星口径结构性压低。
/// 所以这里两者是平级的取值，没有「默认更差」的那一个。
public enum PracticeSessionLength: String, CaseIterable, Equatable, Sendable {
    case standard
    case mini
}

/// 一次练习的创建参数 —— 房间开始会话时用的正是这三样。
///
/// 它是**已经过屏幕校验**的结果：素材建好了才有 `materialID`，
/// 场景与时长是学员选定的。房间不再重复判断合法性。
public struct PracticeCreation: Equatable, Sendable {
    public var materialID: String?
    /// `nil` ＝ **不由客户端指定场景**，交给服务端（见 `CreatePracticeState.sceneType`）。
    public var sceneType: String?
    public var length: PracticeSessionLength

    public init(materialID: String?, sceneType: String?, length: PracticeSessionLength) {
        self.materialID = materialID
        self.sceneType = sceneType
        self.length = length
    }
}

public struct CreatePracticeState: Equatable, Sendable, State {
    /// 稿子：弹层默认停在**「一句话描述」**（冷启动摩擦最低的路径）。
    public var input: CreatePracticeInput
    /// 文本输入的那一份草稿。
    ///
    /// **两种文本输入共用一份**：它们送达服务端的是同一段文字，只是 `kind` 不同，
    /// 而学员在两者之间切换时不该丢掉已经写下/粘上的东西。
    public var draft: String
    /// 预置场景的 id（不是显示名）。MVP 只有 Daily Standup 一个。
    ///
    /// **所以它今天没有任何 action 能改它** —— 一个改不动的东西不该长着「可以被改」的样子。
    /// 第二个预置场景出现时，这里补一个 `presetSceneChanged`，那时它才有派发者。
    public var presetScene: String
    public var length: PracticeSessionLength
    public var isSubmitting: Bool
    public var errorMessage: String?
    /// 提交成功后放在这里，房间开始会话时读它。
    ///
    /// 放在**这一格**而不是房间那一格：创建发生在进入房间之前，房间只是它的消费者。
    /// 下一次提交会覆盖它 —— 这正是「再练一轮」该有的语义。
    public var pendingCreation: PracticeCreation?

    /// MVP 的预置场景只有一个（稿子：`预置场景` MVP 仅 Daily Standup 作为冷启动兜底）。
    public static let dailyStandupScene = "standup"
    /// 粘贴素材的上限（稿子：上限 2000 字），按**字符**计。
    public static let draftCharacterLimit = 2000
    /// 文本输入的下限（稿子：「一句话描述」≥10 字即可开始）。
    public static let minimumDraftCharacters = 10

    public init(
        input: CreatePracticeInput = .sentence,
        draft: String = "",
        presetScene: String = CreatePracticeState.dailyStandupScene,
        length: PracticeSessionLength = .standard,
        isSubmitting: Bool = false,
        errorMessage: String? = nil,
        pendingCreation: PracticeCreation? = nil
    ) {
        self.input = input
        self.draft = draft
        self.presetScene = presetScene
        self.length = length
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.pendingCreation = pendingCreation
    }

    // MARK: - 规则（屏幕只读它们，不在投影里另写一份）

    /// 这一种输入方式要不要文字。
    public var needsDraft: Bool {
        input != .preset
    }

    /// 这一次创建要不要建素材。`nil` ＝ **不建**（预置场景直接开会话）。
    ///
    /// 放在 state 上而不是中间件里 `switch` 一遍：这是产品规则（哪几种输入会产出素材），
    /// 而中间件只该负责「把已经定下来的事做掉」。
    public var materialKind: MaterialKind? {
        switch input {
        case .sentence:
            return .sentence
        case .paste:
            return .paste
        case .preset:
            return nil
        }
    }

    /// 会话的场景。
    ///
    /// 只有**预置场景**那一路由客户端指定；两种文本输入给 `nil`，把场景交给服务端 ——
    /// 稿子写着「一句话描述」由 AI 补全场景设定，客户端硬塞一个 `standup` 会把那句话变成假的。
    public var sceneType: String? {
        input == .preset ? presetScene : nil
    }

    public var characterCount: Int {
        draft.count
    }

    public var isOverLimit: Bool {
        characterCount > Self.draftCharacterLimit
    }

    public var hasEnoughDraft: Bool {
        characterCount >= Self.minimumDraftCharacters
    }

    /// **不能提交的三个理由各是一件事**，所以这里逐条写开，而不是一个复合布尔：
    /// 在飞时不能再点（否则一次点击会建出两份素材）、超限时不能提交、
    /// 文本不够时不能提交（预置场景不看文本）。
    public var canSubmit: Bool {
        if isSubmitting {
            return false
        }
        guard needsDraft else {
            return true
        }
        return hasEnoughDraft && !isOverLimit
    }
}

public enum CreatePracticeAction: Equatable, Sendable, Action {
    case inputChanged(CreatePracticeInput)
    case draftChanged(String)
    case lengthChanged(PracticeSessionLength)
    /// 学员点了「开始练习」。
    case submitTapped
    /// 素材已建好（预置场景那一路是 `materialID == nil`）。
    case created(PracticeCreation)
    case submissionFailed(String)
}

public let createPracticeReducer: Reducer<CreatePracticeState, CreatePracticeAction> = { state, action in
    switch action {
    case let .inputChanged(input):
        state.input = input
        state.errorMessage = nil

    case let .draftChanged(text):
        state.draft = text
        state.errorMessage = nil

    case let .lengthChanged(length):
        state.length = length

    case .submitTapped:
        // 屏幕会把按钮置灰，但**规则不能只活在按钮的 enabled 上**：
        // 一次误触、一次自动化点击，都会绕过它建出本该被拦住的东西。
        guard state.canSubmit else { return }
        state.isSubmitting = true
        state.errorMessage = nil

    case let .created(creation):
        state.isSubmitting = false
        state.errorMessage = nil
        state.pendingCreation = creation

    case let .submissionFailed(message):
        state.isSubmitting = false
        state.errorMessage = message
    }
}
