import FluentWorkCore

extension SpeakingRoomViewModel {
    /// State → the room's plain model.
    ///
    /// `usesAutoVAD` arrives as an **argument** instead of being read off the room's own
    /// state. It is a feature-flag decision — `AppState.usesVoiceVadAuto` derives it from
    /// `featureFlags` — and the screen needs the answer, not the flag's name. Taking it as a
    /// parameter is what keeps this projection a function of things it can be handed in a test.
    ///
    /// `creation` 同理：场景名与「标准/迷你」是**创建练习那一屏**定下来的
    /// （`AppState.createPractice.pendingCreation`），不是房间自己的状态。房间只是消费者。
    public static func make(
        from state: SpeakingRoomState,
        usesAutoVAD: Bool,
        creation: PracticeCreation? = nil
    ) -> SpeakingRoomViewModel {
        SpeakingRoomViewModel(
            phase: state.phase,
            processingStage: state.processingStage,
            liveTranscript: state.liveTranscript,
            lastBadge: state.lastBadge,
            badgeHits: state.badgeHits,
            failureReason: state.failureReason,
            timeline: state.timeline.map { item in
                SpeakingRoomTimelineRow(
                    id: item.id.uuidString,
                    isUser: item.speaker == .user,
                    text: item.text,
                    isListening: item.status == .listening,
                    hits: item.hits.map { hit in
                        SpeakingRoomTimelineHit(
                            // 身份用**reducer 自己那条唯一性不变式**，而不是「块 id 或
                            // 一个常数」。旧的拼法 `phraseBlockID ?? "badge"` 会撞：两条
                            // 只有 badge 的命中同属一轮时 `phraseBlockID` 都是 nil，于是
                            // 两行拿到同一个 id —— 视图在 `ForEach(row.hits)` 里拿它做身份，
                            // 而重复身份在 SwiftUI 里是未定义行为。
                            //
                            // 去重键是 `(badge, phraseBlockID)`（`SpeakingRoomFeature.swift:293-297`
                            // 的 `contains(where:)`），所以这两个字段本身就已经是「一轮之内不重复」
                            // 的保证；让视图身份与 reducer 的键取同一个，两边就不会各自漂移。
                            id: "\(item.id.uuidString)-\(hit.badge)-\(hit.phraseBlockID ?? "none")",
                            badge: hit.badge,
                            phraseBlockID: hit.phraseBlockID
                        )
                    },
                    isStallPoint: item.isStallPoint,
                    wasInterrupted: item.wasInterrupted
                )
            },
            usesAutoVAD: usesAutoVAD,
            isRescueHintAvailable: state.isRescueHintAvailable,
            sceneLabel: sceneLabel(creation: creation),
            roundText: roundText(completedTurns: state.session.userTurnCount),
            lengthText: creation?.length.roomLabel,
            badgeHitText: state.badgeHits > 0 ? "用上 \(state.badgeHits) 个" : nil,
            liveTranscriptFloat: liveTranscriptFloat(from: state),
            rescueHeadline: state.isRescueHintAvailable ? "已经 3 秒没有听到你" : nil,
            rescueReassurance: "慢一点没关系，这不算失败",
            rescueButtonTitle: "给我点儿提示"
        )
    }

    /// 场景名。**认得出的用词表里的中文标签，认不出的就用原值**。
    ///
    /// 两条都不是「兜底成某个已知场景」：那会让屏幕上出现一个确定但错的场景名
    /// （与状态灯同一条纪律）。用原值至少是服务端真说的话。
    private static func sceneLabel(creation: PracticeCreation?) -> String? {
        guard let scene = creation?.sceneType, !scene.isEmpty else { return nil }
        return CorpusSceneFilter(serverTag: scene)?.label ?? scene
    }

    /// 「第 N 轮」＝**正在进行的这一轮**。
    ///
    /// `userTurnCount` 数的是**已经说完**的轮数，所以加一。两种读法都说得通
    /// （「你在第几轮」/「你说完了几轮」），这里取前者 —— 它与稿子 屏 02「第 3 轮」
    /// 底下正好三条气泡的画法一致。**这一条要人在真机上确认**，见走查清单。
    private static func roundText(completedTurns: Int) -> String? {
        "第 \(completedTurns + 1) 轮"
    }

    /// **禁止双重展示**（稿子 屏 02 的「三条易错点」之首）。
    ///
    /// 稿子的两句话各守一件事：
    ///
    /// 1. 「**仅录音时出现**，话音落下后 200ms 淡入归位到气泡」⇒ 不在录音态就没有浮层；
    /// 2. 「**不同时显示同一句话**」⇒ 那句话已经在气泡里了，浮层就不再显示它。
    ///
    /// 第 2 条不是第 1 条的马后炮：`serverASRReceived` **一次动作里同时**写 `liveTranscript`
    /// 与那条气泡，而它到达时相位未必已经翻过录音态（极端时序下服务端转写会先到）。
    /// 只守第 1 条的话，屏幕上就会出现两份同样的字 —— 这正是这一条纪律要挡的东西。
    ///
    /// ⚠️ **今天浮层实际上看不到内容**：`liveTranscript` 唯一的写入者是 `serverASRReceived`
    /// （服务端转写），而它一到就把那句话也写进气泡 —— 于是第 2 条立刻把它从浮层撤掉。
    /// 稿子的「浮层实时滚动」要的是**客户端侧的实时 ASR**，那条链路今天还没接
    /// （`ClientASRTranscriber` 是一份没接线的文档）。见走查清单的「没做的」。
    private static func liveTranscriptFloat(from state: SpeakingRoomState) -> String? {
        guard state.phase == .recording else { return nil }
        let text = state.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let alreadyInABubble = state.timeline.contains { $0.speaker == .user && $0.text == text }
        return alreadyInABubble ? nil : text
    }
}

extension PracticeSessionLength {
    /// 顶部栏里的会话时长名（稿子 屏 02：「第 3 轮 · 标准会话」）。
    public var roomLabel: String {
        switch self {
        case .standard:
            return "标准会话"
        case .mini:
            return "迷你会话"
        }
    }
}
