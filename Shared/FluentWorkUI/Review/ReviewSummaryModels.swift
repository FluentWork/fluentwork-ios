import FluentWorkCore

/// 回顾页顶部那一条总结：`12 分钟 · 9 回合 · +4 新增话术块`（09-26 稿 屏 04）。
///
/// 三个数字各自可能没有：时长要 `duration_sec`、回合数由转录数出来、新增块数由炼化产出数出来。
/// 所以它们是**一个数组**而不是三个字段 —— 少一个就少一项，视图不用为每一项写一个 `if`。
public struct ReviewSummaryViewData: Equatable, Sendable {
    public var facts: [String]

    public init(facts: [String]) {
        self.facts = facts
    }
}

/// 目标达成（稿子 屏 04：「目标达成 · 3 件事说清了 2 件」＋ 一句话）。
///
/// 它排在问题清单**前面**，这是稿子「**先肯定后改进**」的阅读顺序纪律里最硬的一半：
/// 学员往下读的第一件事是「这次哪里做成了」，不是「哪里错了」。
public struct ReviewGoalViewData: Equatable, Sendable {
    /// 服务端的 `goal_achievement.met`。
    public var isMet: Bool
    public var headline: String
    public var note: String

    public init(isMet: Bool, headline: String, note: String) {
        self.isMet = isMet
        self.headline = headline
        self.note = note
    }
}

/// 一条双栏对照：左「你说的」右「更地道的版本」，两侧都带**词级差异标注**。
public struct ReviewComparisonViewData: Equatable, Sendable, Identifiable {
    public var id: String
    public var userText: String
    public var betterText: String
    public var userSegments: [ReviewTextDiff.Segment]
    public var betterSegments: [ReviewTextDiff.Segment]

    public init(
        id: String,
        userText: String,
        betterText: String,
        userSegments: [ReviewTextDiff.Segment],
        betterSegments: [ReviewTextDiff.Segment]
    ) {
        self.id = id
        self.userText = userText
        self.betterText = betterText
        self.userSegments = userSegments
        self.betterSegments = betterSegments
    }
}

/// 双栏对照那一节。
///
/// **首屏只给一条**（`top`），其余在 `remaining` 里 —— 稿子的「阅读顺序纪律」：
/// 「首屏默认只呈现 3 个最高价值点，其余收进『查看全部』；少而精的对照比 8 条对照更有冲击力」。
public struct ReviewComparisonSection: Equatable, Sendable {
    public var top: ReviewComparisonViewData
    public var remaining: [ReviewComparisonViewData]
    /// 稿子画的是「1 / 5」。
    public var counterText: String
    /// 「查看其余 4 条对照」。没有其余时是 `nil`（**不画一个点了没反应的按钮**）。
    public var moreButtonTitle: String?

    public init(
        top: ReviewComparisonViewData,
        remaining: [ReviewComparisonViewData],
        counterText: String,
        moreButtonTitle: String?
    ) {
        self.top = top
        self.remaining = remaining
        self.counterText = counterText
        self.moreButtonTitle = moreButtonTitle
    }
}

/// 一个问题 / 一条建议。
public struct ReviewInsightViewData: Equatable, Sendable, Identifiable {
    public var id: String
    /// 问题：学员当时那句原话；建议：建议本身。
    public var title: String
    /// 问题带一句 hint；建议没有详情。
    public var detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// 问题清单 / 提高建议那一节。与对照节同一套 Top-N 纪律。
public struct ReviewInsightSection: Equatable, Sendable {
    public var top: ReviewInsightViewData
    public var remaining: [ReviewInsightViewData]
    /// 「查看全部 2 条」。没有其余时是 `nil`。
    public var moreButtonTitle: String?

    public init(
        top: ReviewInsightViewData,
        remaining: [ReviewInsightViewData],
        moreButtonTitle: String?
    ) {
        self.top = top
        self.remaining = remaining
        self.moreButtonTitle = moreButtonTitle
    }
}
