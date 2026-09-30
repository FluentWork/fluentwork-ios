import Foundation

/// 话术块的状态灯（PRD 模块 F · F2）。
///
/// ## 它为什么值得单独一个类型
///
/// 服务端把状态放在一个**字符串**里（`PhraseBlock.state`，取值见后端
/// `internal/corpus/types.go:7-11`：`new` / `training` / `automated`），而从服务端的字符串到屏幕上的
/// 一个点，中间有三件各自会错的事：
///
/// 1. **认不出的取值**：服务端加了第四种状态，客户端把它当「新入库」画出来 —— 屏幕上就出现一个
///    看起来确定、其实错的灯。所以 `init?(serverState:)` 返回可选，认不出就是 `nil`：**宁可没有灯，
///    也不要一个错的灯**（同一条纪律，工作台那边是「认不出的模块用它自己的名字」）。
/// 2. **只靠颜色**：稿子 §2.4 明确要求「**不单靠颜色**：空心 ○ / 半实 ◐ / 实心 ●」。色觉障碍下
///    黄与绿是这一对最容易撞的，形态是兜底 —— 所以形态被提到类型上，好让判据能断言三态两两不同。
/// 3. **颜色写两遍**：颜色必须来自令牌（`DesignTokens`），而不是在这里再写一次十六进制
///    （`DesignTokensTests.hexColorLiteralsLiveOnlyInDesignTokens` 盯着这一点）。
///
/// 它住在 UI 模块，因为「形态」与「无障碍说法」是**呈现**的事实，不是领域的事实；
/// 服务端的领域事实是 `PhraseBlock.state` 那个字符串本身。
public enum CorpusStateLamp: String, Equatable, Sendable, CaseIterable {
    /// 新入库。
    case new
    /// 训练中。
    case training
    /// 已自动化。
    case automated

    /// 灯的形状 —— 这一维与颜色**同时**变化，它才是「不单靠颜色」的可判形式。
    public enum Form: String, Equatable, Sendable, CaseIterable {
        /// 空心 ○
        case hollow
        /// 半实 ◐
        case half
        /// 实心 ●
        case solid

        /// 用 SF Symbol 画，不拿 `Circle` 拼半个：拼出来的那半个在动态字体与不同缩放下会走样，
        /// 而这三个符号是系统给的。
        public var symbolName: String {
            switch self {
            case .hollow:
                return "circle"
            case .half:
                return "circle.lefthalf.filled"
            case .solid:
                return "circle.fill"
            }
        }
    }

    /// 形态：三态两两不同（判据 `三态的形态两两不同` 钉住这一点）。
    public var form: Form {
        switch self {
        case .new:
            return .hollow
        case .training:
            return .half
        case .automated:
            return .solid
        }
    }

    /// 颜色取自令牌。返回 hex 而不是 `Color`，是因为 `Color` 没法在判据里可靠地比 ——
    /// 视图用 `DesignTokens.Color.color(forHex:)` 转回去，**表仍然只有一张**。
    public var colorHex: String {
        switch self {
        case .new:
            // 灰点：稿子 §2.4 记了「灰点在深色底需过 AA」，令牌里过 AA 的中性色是 textSecondary。
            return DesignTokens.Hex.textSecondary
        case .training:
            return DesignTokens.Hex.training
        case .automated:
            return DesignTokens.Hex.success
        }
    }

    /// VoiceOver 的说法。稿子 §6：状态灯是纯视觉元素，必须配 `accessibilityLabel`。
    public var accessibilityLabel: String {
        switch self {
        case .new:
            return "新入库"
        case .training:
            return "训练中"
        case .automated:
            return "已自动化"
        }
    }

    /// 服务端 `PhraseBlock.state` → 灯。认不出返回 `nil`（见类型说明第 1 条）。
    ///
    /// 大小写不做宽容：契约里就是小写，`"NEW"` 是**另一个**取值，按不认识处理更难查也更容易发现。
    public init?(serverState: String) {
        switch serverState {
        case "new":
            self = .new
        case "training":
            self = .training
        case "automated":
            self = .automated
        default:
            return nil
        }
    }
}
