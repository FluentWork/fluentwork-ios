import FluentWorkCore

extension DailyReadViewModel {
    /// State → the reading screen's plain model.
    ///
    /// `isOffline` comes in as an **argument**: it belongs to `NetworkConnectivityState`, not to the
    /// reading, and the screen only needs to know whether to say so. Naming it on the signature is
    /// what turns a hidden reach into the root state into a stated dependency.
    public static func make(
        from state: DailyReadState,
        isOffline: Bool
    ) -> DailyReadViewModel {
        let phase: DailyReadViewPhase
        switch state.phase {
        case .idle:
            phase = .idle
        case .generating:
            phase = .loading
        case .ready:
            phase = .ready
        case .fallbackPreset:
            phase = .fallbackPreset
        case .failed:
            phase = .failed
        }

        let article: DailyReadArticle? = state.dailyRead.map {
            DailyReadArticle(
                id: $0.id,
                title: $0.title,
                body: $0.body,
                hasAudio: ($0.audioURL?.isEmpty == false),
                sourceBlockCount: $0.usedBlockIDs.count,
                estimatedReadingSeconds: estimatedReadingSeconds(for: $0.body)
            )
        }

        let audioPhase: DailyReadAudioViewPhase
        switch state.audioPhase {
        case .idle: audioPhase = .idle
        case .loading: audioPhase = .loading
        case .playing: audioPhase = .playing
        case .paused: audioPhase = .paused
        }

        let followReadPhase: FollowReadViewPhase
        switch state.followReadPhase {
        case .idle: followReadPhase = .idle
        case .recording: followReadPhase = .recording
        case .submitting: followReadPhase = .submitting
        case .recorded: followReadPhase = .recorded
        case let .failed(message): followReadPhase = .failed(message)
        }

        return DailyReadViewModel(
            phase: phase,
            article: article,
            fallbackBody: state.fallbackBody,
            genDate: state.genDate,
            audioPhase: audioPhase,
            audioPlaybackTime: state.audioPlaybackTime,
            audioDuration: state.audioDuration,
            followReadPhase: followReadPhase,
            hasFollowRead: state.hasFollowRead,
            isOffline: isOffline,
            errorMessage: state.lastErrorMessage
        )
    }

    /// Approximate reading time: ~200 English words per minute, floor 30 s.
    ///
    /// The floor is not decoration — a one-sentence read would otherwise claim "约 2 秒", and a
    /// number that is obviously wrong is worse than a round one.
    private static func estimatedReadingSeconds(for body: String) -> Int {
        let words = body
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        let seconds = Int((Double(words) / 200.0) * 60.0)
        return max(seconds, 30)
    }
}
