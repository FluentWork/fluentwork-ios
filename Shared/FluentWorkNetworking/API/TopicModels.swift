import Foundation

/// 话题卡的类型（PRD §7.8 H1）。服务端是闭集 `warmup / practice / stretch`。
public enum TopicCardType: String, Codable, Equatable, Sendable {
    case warmup
    case practice
    case stretch
    /// 服务端加了新类型、这一版客户端还不认识。
    ///
    /// 用 `.unknown` 而不是让解码**整条列表**失败：话题卡是「今天的三张」，一张卡的
    /// 类型读不出来，不该把另外两张一起吞掉（与 `DrillBlockState` 同一条理由）。
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TopicCardType(rawValue: raw) ?? .unknown
    }
}

/// 忽略一张卡时的那**四选一**理由（闭集，86_ M11）。
///
/// 是闭集而不是自由文本：它要产生的是**可数**的信号 —— 哪一种「最后一公里」断了。
/// 四个理由各自指向一个不同的修法（`internal/topic/model.go:87-100`）：
/// 没人可聊 → 应用内模拟对话；不敢开口 → 更低的第一步；没时间 → 更短的卡；
/// 话题没用 → 生成还没到位（这是 H1/H2 的质量信号）。
///
/// **文案（中文标签）不在这里**：写用户可见的中文文案是产品决定，见 R5-b 的先例。
/// 这一层只负责「有哪四个」，四个选项长什么样由 UI 票定。
public enum TopicDismissReason: String, Codable, Equatable, Sendable, CaseIterable {
    case noPartner = "no_partner"
    case notConfident = "not_confident"
    case noTime = "no_time"
    case notRelevant = "not_relevant"
}

/// 卡上「可调用话术块清单」里的一条 —— 已为你解析好，可直接显示。
public struct TopicBlockRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var expressionEN: String
    public var intentZH: String

    public init(id: String, expressionEN: String, intentZH: String) {
        self.id = id
        self.expressionEN = expressionEN
        self.intentZH = intentZH
    }

    enum CodingKeys: String, CodingKey {
        case id
        case expressionEN = "expression_en"
        case intentZH = "intent_zh"
    }
}

/// 一张话题卡（`GET /topic-cards` 的一项）。
public struct TopicCard: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var forDate: Date
    public var title: String
    public var promptEN: String
    public var promptZH: String
    public var cardType: TopicCardType
    public var seedTags: [String]
    /// H1 的「可调用话术块清单」，**以 id 形式**。
    public var blockIDs: [String]
    /// 同一份清单，服务端已解析好可供显示。
    ///
    /// 契约里不是必填、服务端也是 `omitempty` ⇒ 省略时是空数组（不是缺数据）。
    public var blocks: [TopicBlockRef]
    /// H2 的**来源标注**：这张卡是从你的哪份素材、哪些标签来的。
    ///
    /// 「一张没有 source_note 的卡，就是服务端没能把它落到你的语料上」——
    /// 所以**不许替它编一句**。`nil` 就是 `nil`。
    public var sourceNote: String?
    public var validUntil: Date
    public var checkedInAt: Date?
    public var dismissedAt: Date?
    public var dismissReason: TopicDismissReason?
    public var createdAt: Date
    public var updatedAt: Date

    /// 打卡是「一次」的事实，时间戳就是它。**不用 `dismissReason` 反推**。
    public var isCheckedIn: Bool { checkedInAt != nil }
    /// 已忽略同样是**时间戳**说了算，原因只是附加说明。
    public var isDismissed: Bool { dismissedAt != nil }

    public init(
        id: String,
        forDate: Date,
        title: String,
        promptEN: String,
        promptZH: String,
        cardType: TopicCardType,
        seedTags: [String],
        blockIDs: [String],
        blocks: [TopicBlockRef] = [],
        sourceNote: String? = nil,
        validUntil: Date,
        checkedInAt: Date? = nil,
        dismissedAt: Date? = nil,
        dismissReason: TopicDismissReason? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.forDate = forDate
        self.title = title
        self.promptEN = promptEN
        self.promptZH = promptZH
        self.cardType = cardType
        self.seedTags = seedTags
        self.blockIDs = blockIDs
        self.blocks = blocks
        self.sourceNote = sourceNote
        self.validUntil = validUntil
        self.checkedInAt = checkedInAt
        self.dismissedAt = dismissedAt
        self.dismissReason = dismissReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case forDate = "for_date"
        case title
        case promptEN = "prompt_en"
        case promptZH = "prompt_zh"
        case cardType = "card_type"
        case seedTags = "seed_tags"
        case blockIDs = "block_ids"
        case blocks
        case sourceNote = "source_note"
        case validUntil = "valid_until"
        case checkedInAt = "checked_in_at"
        case dismissedAt = "dismissed_at"
        case dismissReason = "dismiss_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// 手写解码，只为两处**宽容**，其余字段照旧。
    ///
    /// 1. `card_type` 认不出 ⇒ `.unknown`（见那个类型）；
    /// 2. `dismiss_reason` 认不出 ⇒ `nil`，**而不是**让整张卡解不出来。
    ///    「已忽略」的事实是 `dismissed_at`，原因是附加说明 —— 服务端将来加第五个理由时，
    ///    让一张卡从列表里消失远比「显示成已忽略、但没有原因」更糟。
    ///
    /// 注意这里**不做**的宽容：`source_note` 缺失仍然是 `nil`，不填默认值。
    /// 那正是 H2 要看的信号（没有来源标注 = 这张卡没被落到语料上）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        forDate = try c.decode(Date.self, forKey: .forDate)
        title = try c.decode(String.self, forKey: .title)
        promptEN = try c.decode(String.self, forKey: .promptEN)
        promptZH = try c.decode(String.self, forKey: .promptZH)
        cardType = try c.decode(TopicCardType.self, forKey: .cardType)
        seedTags = try c.decodeIfPresent([String].self, forKey: .seedTags) ?? []
        blockIDs = try c.decodeIfPresent([String].self, forKey: .blockIDs) ?? []
        blocks = try c.decodeIfPresent([TopicBlockRef].self, forKey: .blocks) ?? []
        sourceNote = try c.decodeIfPresent(String.self, forKey: .sourceNote)
        validUntil = try c.decode(Date.self, forKey: .validUntil)
        checkedInAt = try c.decodeIfPresent(Date.self, forKey: .checkedInAt)
        dismissedAt = try c.decodeIfPresent(Date.self, forKey: .dismissedAt)
        // 先解成 `String` 再自己映射，**不能**直接 `decodeIfPresent(TopicDismissReason.self, …)`：
        // `decodeIfPresent` 只在键**缺失或为 null** 时返回 nil，值**非法**时照样抛
        // `dataCorrupted` —— 也就是说「宽容」会漏在我最需要它的那一种输入上。
        // （`cardType` 没这个问题，因为那个类型的 `init(from:)` 自己就吞掉了陌生值。）
        dismissReason = try c.decodeIfPresent(String.self, forKey: .dismissReason)
            .flatMap(TopicDismissReason.init(rawValue:))
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// `GET /topic-cards` 的信封。
public struct TopicCardList: Codable, Equatable, Sendable {
    public var items: [TopicCard]

    public init(items: [TopicCard]) {
        self.items = items
    }
}

/// `POST /topic-cards/:id/checkin` 的请求体（H3）。
///
/// ⚠️ **契约里只声明了 `reflection`**（`api/openapi-v1.yaml` 的 checkin requestBody 内联 schema）。
/// `used_block_ids` 是照**服务端实际读的字段**写的（`internal/topic/model.go:158-162`），
/// 而且响应契约依赖它 —— `TopicCheckinResult.ignored_block_ids` 的说明就是为「客户端发来的
/// 陌生 id」写的。两边不一致是**契约缺口**，不是这里的猜测；已单独记录，未擅自改 yaml。
public struct TopicCheckinRequest: Codable, Equatable, Sendable {
    public var reflection: String
    public var usedBlockIDs: [String]

    public init(reflection: String = "", usedBlockIDs: [String] = []) {
        self.reflection = reflection
        self.usedBlockIDs = usedBlockIDs
    }

    enum CodingKeys: String, CodingKey {
        case reflection
        case usedBlockIDs = "used_block_ids"
    }
}

/// `POST /topic-cards/:id/checkin` 的响应（H3 的「数据回传」那一半）。
public struct TopicCheckinResult: Codable, Equatable, Sendable {
    public var checkinID: String
    public var streakDays: Int
    /// 这张卡上的话术块里，有多少条被记成「真的在对话里用掉了」（86_ M10）。
    ///
    /// **0 不代表打卡失败**：可能是学员一条都没勾，也可能是那本账还没接上。
    /// 这两个含义在这一层分不开，所以 UI 不许把 0 渲染成错误。
    public var recordedUse: Int
    /// 客户端发来、但这张卡从没提供过的 id。服务端**报回来**而不是静默丢掉 ——
    /// 一个会发陌生 id 的客户端有 bug，值得被看见。
    public var ignoredBlockIDs: [String]

    public init(
        checkinID: String,
        streakDays: Int,
        recordedUse: Int,
        ignoredBlockIDs: [String] = []
    ) {
        self.checkinID = checkinID
        self.streakDays = streakDays
        self.recordedUse = recordedUse
        self.ignoredBlockIDs = ignoredBlockIDs
    }

    enum CodingKeys: String, CodingKey {
        case checkinID = "checkin_id"
        case streakDays = "streak_days"
        case recordedUse = "recorded_use"
        case ignoredBlockIDs = "ignored_block_ids"
    }
}

/// `POST /topic-cards/:id/dismiss` 的响应。
public struct TopicDismissResult: Codable, Equatable, Sendable {
    public var cardID: String
    public var reason: TopicDismissReason?
    /// 第一次忽略是 `false`。重复忽略是幂等的，不会报错。
    public var alreadyDismissed: Bool

    public init(cardID: String, reason: TopicDismissReason?, alreadyDismissed: Bool) {
        self.cardID = cardID
        self.reason = reason
        self.alreadyDismissed = alreadyDismissed
    }

    enum CodingKeys: String, CodingKey {
        case cardID = "card_id"
        case reason
        case alreadyDismissed = "already_dismissed"
    }
}

/// `GET /topic-cards/stats` 的响应。
///
/// 契约把**自报**与**应用内观测**分开报（`86_ M9`）：一场真实的会议服务端看不见，
/// 所以 `real_uses_checkin`（自报打卡）与 `real_uses_hit`（应用内命中）永远是两个数 ——
/// 合成一个转化率就等于把观测和自报混在一起。两半各自报出来。
public struct TopicPracticeStats: Codable, Equatable, Sendable {
    public var windowDays: Int
    public var checkins: Int
    public var cardsServed: Int
    public var blocksTotal: Int
    public var blocksUsed: Int
    public var greenBlocks: Int
    public var greenUsed: Int
    public var conversionRate: Double
    public var checkinRate: Double
    public var realUsesHit: Int
    public var realUsesCheckin: Int
    public var dismissReasons: [String: Int]
    public var dismissRate: Double

    public init(
        windowDays: Int,
        checkins: Int,
        cardsServed: Int,
        blocksTotal: Int,
        blocksUsed: Int,
        greenBlocks: Int,
        greenUsed: Int,
        conversionRate: Double,
        checkinRate: Double,
        realUsesHit: Int,
        realUsesCheckin: Int,
        dismissReasons: [String: Int] = [:],
        dismissRate: Double
    ) {
        self.windowDays = windowDays
        self.checkins = checkins
        self.cardsServed = cardsServed
        self.blocksTotal = blocksTotal
        self.blocksUsed = blocksUsed
        self.greenBlocks = greenBlocks
        self.greenUsed = greenUsed
        self.conversionRate = conversionRate
        self.checkinRate = checkinRate
        self.realUsesHit = realUsesHit
        self.realUsesCheckin = realUsesCheckin
        self.dismissReasons = dismissReasons
        self.dismissRate = dismissRate
    }

    enum CodingKeys: String, CodingKey {
        case windowDays = "window_days"
        case checkins
        case cardsServed = "cards_served"
        case blocksTotal = "blocks_total"
        case blocksUsed = "blocks_used"
        case greenBlocks = "green_blocks"
        case greenUsed = "green_used"
        case conversionRate = "conversion_rate"
        case checkinRate = "checkin_rate"
        case realUsesHit = "real_uses_hit"
        case realUsesCheckin = "real_uses_checkin"
        case dismissReasons = "dismiss_reasons"
        case dismissRate = "dismiss_rate"
    }
}

/// 话题卡的 REST 面（**带 token**）。鉴权收在 `DefaultTopicClient` 里，中间件看不到它。
public protocol TopicClientProtocol: Sendable {
    func cards(accessToken: String) async throws -> [TopicCard]
    func checkin(
        accessToken: String,
        cardID: String,
        request: TopicCheckinRequest
    ) async throws -> TopicCheckinResult
    func stats(accessToken: String, days: Int?) async throws -> TopicPracticeStats
    func dismiss(
        accessToken: String,
        cardID: String,
        reason: TopicDismissReason
    ) async throws -> TopicDismissResult
}

public final class TopicAPIClient: TopicClientProtocol, Sendable {
    private let network: NetworkClientProtocol
    private let baseURL: URL

    public init(network: NetworkClientProtocol, baseURL: URL) {
        self.network = network
        self.baseURL = baseURL
    }

    public func cards(accessToken: String) async throws -> [TopicCard] {
        let list = try await decode(
            TopicCardList.self,
            .topicCards(accessToken: accessToken)
        )
        return list.items
    }

    public func checkin(
        accessToken: String,
        cardID: String,
        request: TopicCheckinRequest
    ) async throws -> TopicCheckinResult {
        try await decode(
            TopicCheckinResult.self,
            .topicCheckin(accessToken: accessToken, cardID: cardID, request: request)
        )
    }

    public func stats(accessToken: String, days: Int?) async throws -> TopicPracticeStats {
        try await decode(
            TopicPracticeStats.self,
            .topicStats(accessToken: accessToken, days: days)
        )
    }

    public func dismiss(
        accessToken: String,
        cardID: String,
        reason: TopicDismissReason
    ) async throws -> TopicDismissResult {
        try await decode(
            TopicDismissResult.self,
            .topicDismiss(accessToken: accessToken, cardID: cardID, reason: reason)
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, _ api: FluentWorkAPI) async throws -> T {
        let data = try await network.requestData(
            for: AbsoluteFluentWorkTarget(baseURL: baseURL, api: api)
        )
        do {
            return try SessionHistoryJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(description: error.localizedDescription)
        }
    }
}
