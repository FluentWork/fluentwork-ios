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
        case .createPractice:
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
        }
    }

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
