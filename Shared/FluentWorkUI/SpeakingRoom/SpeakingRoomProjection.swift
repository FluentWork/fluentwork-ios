import FluentWorkCore

extension SpeakingRoomViewModel {
    /// State → the room's plain model.
    ///
    /// `usesAutoVAD` arrives as an **argument** instead of being read off the room's own
    /// state. It is a feature-flag decision — `AppState.usesVoiceVadAuto` derives it from
    /// `featureFlags` — and the screen needs the answer, not the flag's name. Taking it as a
    /// parameter is what keeps this projection a function of things it can be handed in a test.
    public static func make(
        from state: SpeakingRoomState,
        usesAutoVAD: Bool
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
                    }
                )
            },
            usesAutoVAD: usesAutoVAD,
            isRescueHintAvailable: state.isRescueHintAvailable
        )
    }
}
