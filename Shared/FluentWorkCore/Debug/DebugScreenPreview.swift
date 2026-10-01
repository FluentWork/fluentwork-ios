#if DEBUG
import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

/// **看版式用的通道：`FW_SCREEN=<name>`。**
///
/// 它的用途只有一个：把某一屏**摆到模拟器上截一张图**，好在人眼走查里对着稿子看形态。
/// 走查表（`docs/design/ui-walkthrough/`）里那些「闪光真的在闪吗」「间距对不对」的问题，
/// 靠判据答不了 —— 它们需要一张截图，而截图需要一个稳定的入口。
///
/// ## 它与 `DeviceScenarioDriver` 的分工
///
/// `DeviceScenarioDriver`（`FW_SCENARIO`）跑的是**流程**：启动 → 进房间 → 起会话 → 断言。
/// 这里是**摆位**：只把某一屏放到前台，不跑流程、不等待、不断言。
/// 两者都只在 DEBUG 里存在，都不在发布版里。
///
/// ## 数据从哪来
///
/// 需要数据的屏（语料库）**换的是数据面**（`CorpusClientProtocol`），不是往 state 里塞结果 ——
/// 于是 app 走的还是那条真路：`.appear` → 中间件 → 客户端 → 投影 → 视图。
/// 塞 state 的话，截出来的图只能说明「视图能画这些数据」，说明不了中间那几层还通着。
public enum DebugScreenPreview {

    public enum Screen: String {
        /// 创建练习弹层（屏 11）。
        case createPractice
        /// 语料库（屏 08），带样例数据。
        case corpus
        /// 语料库的空态（屏 08 的空态形态）。
        case corpusEmpty
        /// 回顾页（屏 04），带样例产出。
        case review
    }

    public static var configured: Screen? {
        guard let raw = ProcessInfo.processInfo.environment["FW_SCREEN"] else { return nil }
        return Screen(rawValue: raw)
    }

    /// 需要样例数据的屏，在这里把数据面换掉。
    ///
    /// 在**建 store 之前**调用，这样中间件拿到的就是替身。
    public static func installStubsIfNeeded(container: Container) {
        guard let screen = configured else { return }
        switch screen {
        case .corpus:
            container.corpusClient.register { PreviewCorpusClient(blocks: corpusFixture) }
        case .corpusEmpty:
            container.corpusClient.register { PreviewCorpusClient(blocks: []) }
        case .createPractice, .review:
            // 回顾页**不换数据面**，而是直接派一条「轮询回来了」——这一屏的数据面是
            // `SpeechSessionClientProtocol`（房间那个大协议），为截图去替身它，
            // 换来的是「截图能证明轮询路径」的错觉。轮询本身有中间件判据管着，
            // 这里要看的是**产出到手之后那一屏长什么样**。
            break
        }
    }

    /// 摆位：把该屏放到前台。
    @MainActor
    public static func applyIfConfigured(store: AppStore) async {
        guard let screen = configured else { return }
        switch screen {
        case .createPractice:
            // 工作台是启动落地的那一屏，所以直接掀弹层即可。
            store.dispatch(
                .navigation(.workbench(.present(.createPractice, style: .sheet)))
            )
        case .corpus, .corpusEmpty:
            store.dispatch(.navigation(.selectTab(.corpus)))
        case .review:
            // 先让产出落地，再把人送上去 —— 顺序反过来的话，那一帧是空的。
            if let response = reviewFixture {
                store.dispatch(.review(.applyPoll(response)))
            }
            store.dispatch(
                .navigation(
                    .workbench(.present(.review(sessionID: reviewFixtureSessionID), style: .fullScreenCover))
                )
            )
            // **本机没有后端**：进页面时 `.appear` 会去打一次 `GET /sessions/:id/review`，
            // 而它遇到网络错误是**立刻 `.loadFailed`、不重试**（`pollReviewUntilReady`）。
            // 那一下会把相位从 `.ready` 打成 `.failed`，屏幕上就成了「暂不可用」。
            // 所以等它落地之后把样例产出**再种一次** —— 这一屏要看的是产出到手之后的样子。
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(400))
                guard let response = reviewFixture, store.state.review.phase != .ready else { continue }
                store.dispatch(.review(.applyPoll(response)))
            }
        }
    }

    static let reviewFixtureSessionID = "preview-review-session"

    /// 屏 04 的样例产出：**照稿子那张图摆**（9 回合、12 分钟、3 条问题、2 条建议、
    /// 5 条对照里首屏只给 1 条、3 个待入库）。
    static let reviewFixture: ReviewPollResponse? = {
        let json = """
            {
              "session_id": "\(reviewFixtureSessionID)",
              "status": "ready",
              "review": {
                "generator": "ark-review-refine-v1",
                "status": "ready",
                "duration_sec": 720,
                "transcript": [
                  {"seq":1,"speaker":"user","text":"I need to talk about the rate limiting plan."},
                  {"seq":2,"speaker":"ai","text":"Sure, go ahead."},
                  {"seq":3,"speaker":"user","text":"I will do the cache thing next week."},
                  {"seq":4,"speaker":"ai","text":"Got it. What's the risk?"},
                  {"seq":5,"speaker":"user","text":"There is a risk we might be late."},
                  {"seq":6,"speaker":"ai","text":"Thanks for flagging that."},
                  {"seq":7,"speaker":"user","text":"I think maybe we can try that."},
                  {"seq":8,"speaker":"ai","text":"Let's note it down."},
                  {"seq":9,"speaker":"user","text":"We need to, uh, do it later."},
                  {"seq":10,"speaker":"user","text":"Maybe it is not a good idea."},
                  {"seq":11,"speaker":"user","text":"I am blocked on the API review."},
                  {"seq":12,"speaker":"user","text":"I will follow up tomorrow."}
                ],
                "overview": {
                  "goal_achievement": {
                    "met": true,
                    "note": "讲清了限流方案的目的与当前进度，没提到预计完成时间。"
                  },
                  "issue_count": 3,
                  "suggestion_count": 2,
                  "comparison_count": 5
                },
                "evaluation": [],
                "dual_column": [
                  {
                    "user": "I will do the cache thing next week.",
                    "better": "I'll get the caching work wrapped up next week."
                  },
                  {
                    "user": "We need to, uh, do it later.",
                    "better": "Let's push the launch to next sprint."
                  },
                  {
                    "user": "There is a risk we might be late.",
                    "better": "There's a risk we might slip here."
                  },
                  {
                    "user": "I think maybe we can try that.",
                    "better": "I'd suggest we try that."
                  },
                  {
                    "user": "I am blocked on the API review.",
                    "better": "I'm blocked on the API review."
                  }
                ],
                "refine_cards": [
                  {
                    "intent_zh": "需要推迟某个话题时说",
                    "expression_en": "Let's push the launch to next sprint.",
                    "anchor_user_said": "We need to do it later.",
                    "scene_tag": "standup",
                    "function_tag": "defer"
                  },
                  {
                    "intent_zh": "表达「这块我来兜底」时",
                    "expression_en": "I'll take ownership of that piece.",
                    "anchor_user_said": "I will do this part.",
                    "scene_tag": "standup",
                    "function_tag": "commit"
                  },
                  {
                    "intent_zh": "需要同步风险时说",
                    "expression_en": "There's a risk we might slip here.",
                    "anchor_user_said": "We might be late.",
                    "scene_tag": "review",
                    "function_tag": "report"
                  }
                ],
                "review": {
                  "goal_achievement": {
                    "met": true,
                    "note": "讲清了限流方案的目的与当前进度，没提到预计完成时间。"
                  },
                  "issues": [
                    {
                      "type": "vague_time",
                      "original_quote": "I will do the cache thing next week.",
                      "hint": "「下周」太松，给一个具体日子。"
                    },
                    {
                      "type": "filler",
                      "original_quote": "We need to, uh, do it later.",
                      "hint": "填词 uh 让这句话听起来不确定。"
                    },
                    {
                      "type": "hedging",
                      "original_quote": "I think maybe we can try that.",
                      "hint": "两个弱化词连用，把主张说没了。"
                    }
                  ],
                  "suggestions": [
                    {"text": "把「我下周弄」换成「我下周三之前给你」。"},
                    {"text": "同步风险时先给结论，再给原因。"}
                  ],
                  "comparisons": [
                    {
                      "user": "I will do the cache thing next week.",
                      "better": "I'll get the caching work wrapped up next week."
                    }
                  ]
                },
                "refine": {
                  "blocks": [
                    {
                      "intent_zh": "需要推迟某个话题时说",
                      "expression_en": "Let's push the launch to next sprint.",
                      "anchor_user_said": "We need to do it later.",
                      "scene_tag": "standup",
                      "function_tag": "defer"
                    },
                    {
                      "intent_zh": "表达「这块我来兜底」时",
                      "expression_en": "I'll take ownership of that piece.",
                      "anchor_user_said": "I will do this part.",
                      "scene_tag": "standup",
                      "function_tag": "commit"
                    },
                    {
                      "intent_zh": "需要同步风险时说",
                      "expression_en": "There's a risk we might slip here.",
                      "anchor_user_said": "We might be late.",
                      "scene_tag": "review",
                      "function_tag": "report"
                    },
                    {
                      "intent_zh": "承诺一个具体时间时",
                      "expression_en": "I'll follow up by Wednesday.",
                      "anchor_user_said": "I will follow up tomorrow.",
                      "scene_tag": "standup",
                      "function_tag": "commit"
                    }
                  ]
                }
              }
            }
            """
        return try? JSONDecoder().decode(ReviewPollResponse.self, from: Data(json.utf8))
    }()

    /// 样例话术块：形状照着 09-26 稿 屏 08 那张图 —— 三态各一个、其中一个已自动化并真的用过。
    /// 文案是**稿子里的**那几句（演示数据在稿子里本来就是占位符）。
    static let corpusFixture: [PhraseBlock] = [
        PhraseBlock(
            id: "preview-1",
            intentZH: "需要推迟某个话题时说",
            expressionEN: "Let's push the launch to next sprint.",
            anchorUserSaid: "We need to, uh, do it later.",
            sceneTag: "standup",
            functionTag: "defer",
            state: "automated",
            successStreak: 4,
            nextDueAt: "2026-10-07T00:00:00Z",
            easeFactor: 2.6,
            realUseCount: 3,
            isFavorite: true,
            pinnedAt: nil,
            sourceSessionID: "preview-session",
            createdAt: "2026-09-24T00:00:00Z",
            updatedAt: "2026-09-30T00:00:00Z"
        ),
        PhraseBlock(
            id: "preview-2",
            intentZH: "表达「这块我来兜底」时",
            expressionEN: "I'll take ownership of that piece.",
            anchorUserSaid: "I will do this part.",
            sceneTag: "standup",
            functionTag: "commit",
            state: "training",
            successStreak: 2,
            nextDueAt: "2026-10-02T00:00:00Z",
            easeFactor: 2.5,
            realUseCount: 1,
            isFavorite: false,
            pinnedAt: nil,
            sourceSessionID: "preview-session",
            createdAt: "2026-09-25T00:00:00Z",
            updatedAt: "2026-09-30T00:00:00Z"
        ),
        PhraseBlock(
            id: "preview-3",
            intentZH: "需要同步风险时",
            expressionEN: "There's a risk we might slip here.",
            anchorUserSaid: "Maybe we are late.",
            sceneTag: "review",
            functionTag: "report",
            state: "new",
            successStreak: 0,
            nextDueAt: "2026-10-01T00:00:00Z",
            easeFactor: 2.5,
            realUseCount: 0,
            isFavorite: false,
            pinnedAt: nil,
            sourceSessionID: nil,
            createdAt: "2026-09-30T00:00:00Z",
            updatedAt: "2026-09-30T00:00:00Z"
        ),
    ]
}

/// 只读的样例客户端：`listBlocks` 回那一份固定数据，写操作什么都不做。
///
/// 它**故意不回 `nextCursor`** —— 列表取完了，所以截图上不会出现那句
/// 「（还有更多没加载）」，画面就是稿子画的那一屏。
private final class PreviewCorpusClient: CorpusClientProtocol, @unchecked Sendable {
    private let blocks: [PhraseBlock]

    init(blocks: [PhraseBlock]) {
        self.blocks = blocks
    }

    func listBlocks(
        cursor: String?,
        updatedAfter: String?,
        limit: Int?,
        favoriteOnly: Bool
    ) async throws -> ListPhraseBlocksResponse {
        ListPhraseBlocksResponse(
            items: favoriteOnly ? blocks.filter(\.isFavorite) : blocks,
            nextCursor: nil,
            cursorReset: false
        )
    }

    func setFavorite(blockID: String, isFavorite: Bool, pinned: Bool) async throws -> PhraseBlock {
        blocks.first { $0.id == blockID } ?? PhraseBlock.previewPlaceholder
    }

    func deleteBlock(blockID: String) async throws {}

    func batchAccept(
        sourceSessionID: String,
        cards: [RefineCard]
    ) async throws -> BatchAcceptBlocksResponse {
        // 截图通道不走这条路（它要的是回顾页 + 一次真实的入库）。真的被调到就抛，
        // 而不是回一份假的成功 —— 那会让人以为「入库成功了」而屏幕上什么都没发生。
        throw PreviewClientError.unusedPath
    }
}

private enum PreviewClientError: Error {
    case unusedPath
}

extension PhraseBlock {
    fileprivate static var previewPlaceholder: PhraseBlock {
        DebugScreenPreview.corpusFixture[0]
    }
}
#endif
