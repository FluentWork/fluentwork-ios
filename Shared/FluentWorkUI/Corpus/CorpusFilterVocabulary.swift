import FluentWorkCore
import Foundation

/// 语料库的两个筛选维度（09-26 稿 屏 08：场景 / 功能双维度筛选）。
///
/// **取值是闭集，而且不是我们定的**：`PhraseBlock.scene_tag` / `function_tag` 在契约里就是
/// 带 `enum` 的字段（`openapi-v1.yaml` 的 `PhraseBlock`），服务端还拿同一份闭集校验写入。
/// 所以这里**照抄契约的取值**，并由 `CorpusFilterVocabularyTests` 逐字对着契约核 ——
/// 后端加一个标签而这里没跟上的话，那条判据会红，而不是让人在某天发现「有个标签筛不出来」。
///
/// 中文标签是**呈现**（所以住在 UI 模块），而稿子只给了其中四个（Standup / Design Review /
/// 1:1 / 面试、表达反对 / 请求澄清 / 汇报进度 / 推迟排期），其余按同一口吻补齐 —— 补的这几条
/// 要有人在真机上过一遍，见 `docs/design/ui-walkthrough/`。
public enum CorpusSceneFilter: String, CaseIterable, Sendable, Identifiable {
    case standup
    case review
    case oneOnOne = "1on1"
    case interview
    case casual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standup:
            return "Standup"
        case .review:
            return "Design Review"
        case .oneOnOne:
            return "1:1"
        case .interview:
            return "面试"
        case .casual:
            return "闲聊"
        }
    }
}

public enum CorpusFunctionFilter: String, CaseIterable, Sendable, Identifiable {
    case object
    case clarify
    case report
    case propose
    case agree
    case disagree
    case ask
    case summarize
    case `defer`
    case commit

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .object:
            return "表达反对"
        case .clarify:
            return "请求澄清"
        case .report:
            return "汇报进度"
        case .propose:
            return "提出建议"
        case .agree:
            return "表示同意"
        case .disagree:
            return "表示不同意"
        case .ask:
            return "提出问题"
        case .summarize:
            return "总结要点"
        case .defer:
            return "推迟排期"
        case .commit:
            return "承诺跟进"
        }
    }
}

extension CorpusSceneFilter {
    /// 服务端给的取值认不出时 → `nil`。
    ///
    /// 与状态灯同一条纪律：认不出的取值**不假装认得**。筛选上「猜错」的代价比灯更大 ——
    /// 它会筛出一份看起来正常、其实少了东西的列表。
    public init?(serverTag: String) {
        self.init(rawValue: serverTag)
    }

    public var serverTag: String { rawValue }
}

extension CorpusFunctionFilter {
    public init?(serverTag: String) {
        self.init(rawValue: serverTag)
    }

    public var serverTag: String { rawValue }
}
