import FluentWorkCore
import Foundation

extension SessionHistoryViewModel {
    /// State → the list's plain model.
    ///
    /// `now` and `calendar` are **parameters**, not reads of the clock inside. The rule that matters
    /// here — "今天 14:32" vs "昨天 14:32" vs "9月10日 14:32" — is a function of the current time, so
    /// a projection that calls `Date()` itself can only be checked by a test that happens to run on
    /// the same day, in the same time zone, as the machine that wrote the expectation. Passing them
    /// in makes the labels pinnable.
    ///
    /// `now` is also read **once** and handed to every row: a list of thirty rows that each called
    /// `Date()` could straddle midnight and disagree about which rows are 今天.
    public static func make(
        from state: SessionHistoryState,
        now: Date,
        calendar: Calendar = .current
    ) -> SessionHistoryViewModel {
        let phase: SessionHistoryViewPhase
        switch state.phase {
        case .idle:
            phase = .idle
        case .loading:
            phase = .loading
        case .ready:
            phase = .ready
        case .empty:
            phase = .empty
        case .failed:
            phase = .failed
        }

        return SessionHistoryViewModel(
            phase: phase,
            rows: state.items.map { item in
                SessionHistoryRowViewData(
                    id: item.sessionID,
                    startedAtText: SessionHistoryFormatting.startedAt(
                        item.startedAt,
                        now: now,
                        calendar: calendar
                    ),
                    durationText: SessionHistoryFormatting.duration(item.durationSec),
                    statusText: SessionHistoryFormatting.status(item.status)
                )
            },
            canLoadMore: state.hasMore,
            isLoadingMore: state.isLoadingMore,
            errorMessage: state.errorMessage
        )
    }
}

extension SessionDetailViewModel {
    /// State → the detail screen's plain model.
    ///
    /// `isUser` comes from the wire's `speaker` string compared against `"user"`, and anything else —
    /// known-unknown or genuinely new — renders as the other side with its own label rather than
    /// being dropped. A transcript that silently loses turns is worse than one that labels them
    /// oddly.
    public static func make(
        from state: SessionHistoryDetailState,
        now: Date,
        calendar: Calendar = .current
    ) -> SessionDetailViewModel {
        let phase: SessionDetailViewPhase
        switch state.phase {
        case .idle:
            phase = .idle
        case .loading:
            phase = .loading
        case .ready:
            phase = .ready
        case .failed:
            phase = .failed
        }

        // 失败那句话**先取出来**，两条出口都要带上。
        //
        // 它原来只出现在「有 detail」那条出口上，而 `guard` 早退那条**恰好是失败最常走的路**
        // （拉一个会话失败时还没有 detail）—— 于是服务端给的原因被丢掉，屏幕退到那句通用兜底
        // 「检查网络后重试。」（`SessionDetailView.swift:95` 的 `??`）。相邻的列表投影是无条件
        // 传递的，两处不一致，而没有判据能看出来（这一层此前在 app target、零判据）。
        let errorMessage = state.phase.errorMessage

        guard let detail = state.detail else {
            return SessionDetailViewModel(phase: phase, errorMessage: errorMessage)
        }

        let subtitle = [
            SessionHistoryFormatting.startedAt(detail.startedAt, now: now, calendar: calendar),
            SessionHistoryFormatting.duration(detail.durationSec),
        ].joined(separator: " · ")

        return SessionDetailViewModel(
            phase: phase,
            subtitleText: subtitle,
            turns: detail.utterances
                .sorted { $0.seq < $1.seq }
                .map { utterance in
                    SessionDetailTurnViewData(
                        id: utterance.seq,
                        isUser: utterance.speaker == "user",
                        speakerLabel: speakerLabel(utterance.speaker),
                        text: utterance.text
                    )
                },
            errorMessage: errorMessage
        )
    }

    /// `user` / `ai` are the two the backend sends. A third one keeps its own name instead of being
    /// folded into "AI" — the transcript is the one place where every turn has to be attributable to
    /// somebody, and mislabelling one is worse than showing a word the reader has not seen before.
    private static func speakerLabel(_ speaker: String) -> String {
        switch speaker {
        case "user": return "我"
        case "ai": return "AI"
        default: return speaker
        }
    }
}
