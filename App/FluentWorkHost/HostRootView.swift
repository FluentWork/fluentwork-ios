import FluentWorkCore
import FluentWorkFeatureFlags
import FluentWorkUI
import SwiftUI

@MainActor
struct HostRootView: View {
    var store: AppStore
    @State private var didLaunch = false
    @State private var showsEndSessionConfirmation = false

    var body: some View {
        AppRootTabView(
            navigation: store.state.navigation,
            dispatch: { store.dispatch($0) },
            workbenchRoot: { workbenchRoot },
            flashRoot: {
                Text("闪测（占位）")
                    .foregroundStyle(.secondary)
            },
            corpusRoot: {
                CorpusRootView(
                    model: makeCorpusViewModel(from: store.state.corpus),
                    onAppear: {
                        store.dispatch(.corpus(.appear))
                    },
                    onRefresh: {
                        store.dispatch(.corpus(.refreshRequested))
                    },
                    onLoadMore: {
                        store.dispatch(.corpus(.loadMoreRequested))
                    },
                    onToggleFavorite: { blockID, isFavorite in
                        store.dispatch(.corpus(.favoriteToggled(blockID: blockID, isFavorite: isFavorite, pinned: isFavorite)))
                    },
                    onDelete: { blockID in
                        store.dispatch(.corpus(.deleteTapped(blockID: blockID)))
                    },
                    onSearchQueryChanged: { query in
                        store.dispatch(.corpus(.searchQueryChanged(query)))
                    },
                    onFavoriteOnlyChanged: { favoriteOnly in
                        store.dispatch(.corpus(.favoriteOnlyChanged(favoriteOnly)))
                    }
                )
            },
            settingsRoot: {
                SettingsRootView(
                    model: makeSettingsViewModel(from: store.state.featureFlags),
                    onToggleFlag: { rawValue, isEnabled in
                        guard let flag = AppFeatureFlag(rawValue: rawValue) else { return }
                        store.dispatch(.featureFlags(.setLocalOverride(flag: flag, isEnabled: isEnabled)))
                    },
                    onClearOverrides: {
                        store.dispatch(.featureFlags(.clearLocalOverrides))
                    }
                )
            },
            destination: { route in
                AnyView(routeDestination(route))
            }
        )
        .task {
            guard !didLaunch else { return }
            didLaunch = true
            store.dispatch(.lifecycle(.appLaunched))
        }
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case let .speakingRoom(sessionID):
            ZStack(alignment: .top) {
                SpeakingRoomView(
                    model: makeSpeakingRoomViewModel(from: store.state.speakingRoom),
                    onStartTapped: {
                        switch makeSpeakingRoomViewModel(from: store.state.speakingRoom).startTapIntent {
                        case .startSession:
                            restartOrStartSpeakingSession()
                        case .beginTurn:
                            store.dispatch(.speakingRoom(.manualSpeechBegin))
                        case .none:
                            break
                        }
                    },
                    onStopTapped: {
                        switch makeSpeakingRoomViewModel(from: store.state.speakingRoom).stopTapIntent {
                        case .endTurn:
                            store.dispatch(.speakingRoom(.manualSpeechEnd))
                        case .none:
                            break
                        }
                    },
                    onHitTapped: { hit in
                        guard let blockID = hit.phraseBlockID,
                              !blockID.isEmpty else { return }
                        store.dispatch(.corpus(.favoriteToggled(
                            blockID: blockID,
                            isFavorite: true,
                            pinned: true
                        )))
                    },
                    onDebugBadgeInjected: { tier, hitNumber in
                        // DEBUG-only B12 / I11 verification path. Mirrors the
                        // shape of the backend `feedback.badge` frame so the
                        // full wiring — SpeakingRoomFeature.badgeHit →
                        // appCrossCuttingReducer → BadgeFeedbackReducer →
                        // BadgeFeedbackOverlay — can be exercised without a
                        // real B12 corpus hit.
                        let sample = [
                            "地道表达 +1",
                            "ship it",
                            "let's wrap up",
                            "表达自然"
                        ][(hitNumber - 1) % 4]
                        store.dispatch(
                            .speakingRoom(
                                .badgeHit(
                                    badge: sample,
                                    phraseBlockID: "debug-\(hitNumber)",
                                    tier: tier,
                                    turnID: "turn-debug-\(hitNumber)"
                                )
                            )
                        )
                    }
                )
                .navigationTitle("说的房间")

                // `I11` lightweight badge feedback — non-modal, top of the
                // surface, renders only the entries currently inside the
                // visible window. The wrapper uses TimelineView so expired
                // entries fade without forcing a state dispatch.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BadgeFeedbackOverlay(
                        model: makeBadgeFeedbackViewModel(
                            from: store.state.badgeFeedback,
                            now: context.date
                        )
                    )
                    .allowsHitTesting(false)
                }
                .padding(.top, 4)
            }
            .overlay(alignment: .topLeading) {
                Button {
                    closeSpeakingRoom()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.leading, 16)
                .padding(.top, 8)
                .accessibilityLabel("关闭说的房间")
            }
            .safeAreaInset(edge: .bottom) {
                speakingRoomBottomBar
            }
            .onAppear {
                // The route's `sessionID` is the session to *continue from*,
                // and this is where it stops being a route parameter and
                // becomes state. Dispatching on appear — rather than reading
                // the route when a session starts — is what makes leaving and
                // re-entering with a different id take effect.
                //
                // A plain entry from the workbench passes nil, which is what
                // clears a continuation left over from a previous visit.
                store.dispatch(.speakingRoom(.enterRoom(continueFrom: sessionID)))
            }
        case let .review(sessionID):
            let effectiveSessionID = sessionID ?? store.state.speakingRoom.lastSessionID
            ReviewRootView(
                model: makeReviewViewModel(from: store.state.review),
                onAppear: {
                    store.dispatch(.review(.appear(sessionID: effectiveSessionID)))
                },
                onRetry: {
                    let targetSessionID = store.state.review.sessionID ?? effectiveSessionID
                    guard let targetSessionID, !targetSessionID.isEmpty else { return }
                    store.dispatch(.review(.loadRequested(sessionID: targetSessionID)))
                },
                onAcceptRefineCard: { cardID in
                    store.dispatch(.review(.acceptRefineCardTapped(cardID: cardID)))
                }
            )
            .overlay(alignment: .topLeading) {
                Button {
                    dismissWorkbenchModal()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.leading, 16)
                .padding(.top, 8)
                .accessibilityLabel("关闭回顾")
            }
        case let .dailyRead(sessionID):
            DailyReadRootView(
                model: makeDailyReadViewModel(from: store.state.dailyRead, isOffline: !store.state.network.isConnected),
                onAppear: {
                    store.dispatch(.dailyRead(.loadTriggered))
                },
                onRetry: {
                    store.dispatch(.dailyRead(.clear))
                    store.dispatch(.dailyRead(.loadTriggered))
                },
                onPlayTapped: {
                    store.dispatch(.dailyRead(.playTapped))
                },
                onPauseTapped: {
                    store.dispatch(.dailyRead(.pauseTapped))
                },
                onFollowReadStarted: {
                    store.dispatch(.dailyRead(.followReadRecordingStarted))
                },
                onFollowReadSubmitted: {
                    store.dispatch(.dailyRead(.followReadSubmitted))
                }
            )
            .onAppear { _ = sessionID }
        case .sessionHistory:
            SessionHistoryRootView(
                model: makeSessionHistoryViewModel(from: store.state.sessionHistory),
                onAppear: {
                    store.dispatch(.sessionHistory(.appear))
                },
                onRefresh: {
                    store.dispatch(.sessionHistory(.refreshRequested))
                },
                onLoadMore: {
                    store.dispatch(.sessionHistory(.loadMoreRequested))
                },
                onSelect: { sessionID in
                    store.dispatch(.navigation(.workbench(.push(.sessionDetail(sessionID: sessionID)))))
                }
            )
        case let .sessionDetail(sessionID):
            SessionDetailView(
                model: makeSessionDetailViewModel(from: store.state.sessionHistory.detail),
                onAppear: {
                    // Re-requesting on appear is what makes back-and-forth
                    // work: the state holds one session, and coming back to a
                    // different row must not show the previous one.
                    store.dispatch(.sessionHistory(.detailRequested(sessionID: sessionID)))
                },
                onRetry: {
                    store.dispatch(.sessionHistory(.detailRequested(sessionID: sessionID)))
                },
                onContinue: {
                    // Presented rather than pushed: the room is a full-screen
                    // conversational surface everywhere else, and making it a
                    // pushed page in this one path would give the same screen
                    // two behaviours depending on where it was opened from.
                    store.dispatch(
                        .navigation(.workbench(.present(
                            .speakingRoom(sessionID: sessionID),
                            style: .fullScreenCover
                        )))
                    )
                }
            )
        }
    }

    @ViewBuilder
    private var speakingRoomBottomBar: some View {
        switch store.state.speakingRoom.phase {
        case .idle, .failed:
            EmptyView()
        case .ended:
            VStack(spacing: 8) {
                let hits = currentRoundHits()
                if !hits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本轮要点")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(hits, id: \.self) { hit in
                            Label(hit.badge, systemImage: "sparkles")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button {
                        openReviewForLastSession()
                    } label: {
                        Label("查看回顾", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.state.speakingRoom.lastSessionID == nil)

                    Button {
                        dismissWorkbenchModal()
                    } label: {
                        Label("返回工作台", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        case .connecting, .recording, .waitingUser,
             .processing,
             .aiSpeaking, .degradedText:
            // This ends the whole session, not the current turn — the label has
            // to say so, and a mis-tap must not be enough to lose a practice run.
            Button {
                showsEndSessionConfirmation = true
            } label: {
                Label("结束练习", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .confirmationDialog(
                "结束这次练习？",
                isPresented: $showsEndSessionConfirmation,
                titleVisibility: .visible
            ) {
                Button("结束练习", role: .destructive) {
                    store.dispatch(.speakingRoom(.session(.endTap)))
                }
                Button("继续练习", role: .cancel) {}
            } message: {
                Text("会话会结束并生成回顾，本轮要点会保留。")
            }
        }
    }

    private func currentRoundHits() -> [BadgeHitRef] {
        var seen = Set<String>()
        var unique: [BadgeHitRef] = []
        for hit in store.state.speakingRoom.timeline.flatMap(\.hits) {
            let key = hit.phraseBlockID ?? hit.badge
            if seen.insert(key).inserted {
                unique.append(hit)
            }
        }
        return unique
    }

    private func openReviewForLastSession() {
        guard let sessionID = store.state.speakingRoom.lastSessionID,
              !sessionID.isEmpty else {
            return
        }
        store.dispatch(.navigation(.workbench(.dismiss)))
        store.dispatch(
            .navigation(.workbench(.present(
                .review(sessionID: sessionID),
                style: .fullScreenCover
            )))
        )
    }

    private func makeSpeakingRoomViewModel(
        from state: SpeakingRoomState
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
                            id: "\(hit.phraseBlockID ?? "badge")-\(item.id.uuidString)",
                            badge: hit.badge,
                            phraseBlockID: hit.phraseBlockID
                        )
                    }
                )
            },
            usesAutoVAD: store.state.usesVoiceVadAuto
        )
    }

    /// State → the settings screen's plain model.
    ///
    /// Shows the **effective** value next to whether it came from an override,
    /// because those are the two things a device run needs to tell apart: a
    /// flag turned on by a local override behaves exactly like one that is on
    /// by default, and only one of them survives a reinstall.
    private func makeSettingsViewModel(from state: FeatureFlagsState) -> SettingsViewModel {
        let flags = AppFeatureFlag.allCases.map { flag in
            SettingsViewModel.FlagRow(
                id: flag.rawValue,
                title: flag.rawValue,
                isEnabled: state.isEnabled(flag),
                isOverridden: state.localOverrides[flag] != nil
            )
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return SettingsViewModel(
            flags: flags,
            appVersion: version ?? "—",
            hasOverrides: !state.localOverrides.isEmpty
        )
    }

    private func makeReviewViewModel(from state: ReviewState) -> ReviewViewModel {
        let phase: ReviewViewPhase
        switch state.phase {
        case .idle:
            phase = .idle
        case .loading:
            phase = .loading
        case .pending:
            phase = .pending
        case .ready:
            phase = .ready
        case .failed:
            phase = .failed
        }

        let overview = state.payload.map {
            ReviewOverviewViewData(
                note: $0.overview.goalAchievement.note,
                issueCount: $0.overview.issueCount,
                suggestionCount: $0.overview.suggestionCount,
                comparisonCount: $0.overview.comparisonCount
            )
        }
        let transcript = state.payload?.transcript.map {
            ReviewTranscriptRow(id: $0.id, speaker: $0.speaker, text: $0.text)
        } ?? []
        let dualColumn = state.payload?.dualColumn.map {
            ReviewComparisonRow(id: $0.id, user: $0.user, better: $0.better)
        } ?? []
        let refineCards = state.payload?.refineCards.map {
            ReviewRefineCardRow(
                id: $0.id,
                intentZH: $0.intentZH,
                expressionEN: $0.expressionEN,
                anchorUserSaid: $0.anchorUserSaid,
                isAccepting: state.acceptingRefineCardIDs.contains($0.id),
                isAccepted: state.acceptedRefineCardIDs.contains($0.id)
            )
        } ?? []

        return ReviewViewModel(
            phase: phase,
            overview: overview,
            transcript: transcript,
            dualColumn: dualColumn,
            refineCards: refineCards,
            refineErrorMessage: state.acceptErrorMessage,
            errorMessage: state.lastErrorMessage
        )
    }

    private func makeCorpusViewModel(from state: CorpusState) -> CorpusViewModel {
        let phase: CorpusViewPhase
        switch state.phase {
        case .idle:
            phase = .idle
        case .loading:
            phase = .loading
        case .ready:
            phase = .ready
        case .failed:
            phase = .failed
        case .migrating:
            phase = .migrating
        }

        return CorpusViewModel(
            phase: phase,
            rows: state.visibleItems.map {
                CorpusRowViewData(
                    id: $0.id,
                    intentZH: $0.intentZH,
                    expressionEN: $0.expressionEN,
                    anchorUserSaid: $0.anchorUserSaid,
                    sceneTag: $0.sceneTag,
                    functionTag: $0.functionTag,
                    isFavorite: $0.isFavorite,
                    hasPendingFavorite: state.isPending(blockID: $0.id, operation: .favorite),
                    hasPendingDelete: state.isPending(blockID: $0.id, operation: .delete),
                    updatedAt: $0.updatedAt
                )
            },
            searchQuery: state.searchQuery,
            favoriteOnly: state.favoriteOnly,
            isRefreshing: state.isRefreshing,
            isReplayingOutbox: state.isReplayingOutbox,
            canLoadMore: state.nextCursor != nil,
            errorMessage: state.lastErrorMessage
        )
    }

    /// State → the list's plain model.
    ///
    /// `now` is read **once** and handed to every row: a list of thirty rows
    /// that each called `Date()` could straddle midnight and disagree about
    /// which rows are 今天.
    private func makeSessionHistoryViewModel(
        from state: SessionHistoryState
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

        let now = Date()
        return SessionHistoryViewModel(
            phase: phase,
            rows: state.items.map { item in
                SessionHistoryRowViewData(
                    id: item.sessionID,
                    startedAtText: SessionHistoryFormatting.startedAt(item.startedAt, now: now),
                    durationText: SessionHistoryFormatting.duration(item.durationSec),
                    statusText: SessionHistoryFormatting.status(item.status)
                )
            },
            canLoadMore: state.hasMore,
            isLoadingMore: state.isLoadingMore,
            errorMessage: state.errorMessage
        )
    }

    /// State → the detail screen's plain model.
    ///
    /// `isUser` comes from the wire's `speaker` string compared against
    /// `"user"`, and anything else — known-unknown or genuinely new — renders
    /// as the other side with its own label rather than being dropped. A
    /// transcript that silently loses turns is worse than one that labels them
    /// oddly.
    private func makeSessionDetailViewModel(
        from state: SessionHistoryDetailState
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

        guard let detail = state.detail else {
            return SessionDetailViewModel(phase: phase)
        }

        let now = Date()
        let subtitle = [
            SessionHistoryFormatting.startedAt(detail.startedAt, now: now),
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
                        speakerLabel: Self.speakerLabel(utterance.speaker),
                        text: utterance.text
                    )
                },
            errorMessage: state.phase.errorMessage
        )
    }

    /// `user` / `ai` are the two the backend sends. A third one keeps its own
    /// name instead of being folded into "AI" — the transcript is the one place
    /// where every turn has to be attributable to somebody, and mislabelling
    /// one is worse than showing a word the reader has not seen before.
    private static func speakerLabel(_ speaker: String) -> String {
        switch speaker {
        case "user": return "我"
        case "ai": return "AI"
        default: return speaker
        }
    }

    private func makeBadgeFeedbackViewModel(
        from state: BadgeFeedbackState,
        now: Date
    ) -> BadgeFeedbackViewModel {
        let visible = state.visibleEntries(at: now)
        let rows = visible.map { entry in
            BadgeFeedbackRow(
                id: entry.id.uuidString,
                badge: entry.badge,
                tier: mapTier(entry.tier)
            )
        }
        return BadgeFeedbackViewModel(
            badges: rows,
            maxVisible: state.maxVisibleEntries
        )
    }

    private func mapTier(_ tier: BadgeFeedEntry.Tier) -> BadgeFeedbackRow.BadgeTier {
        switch tier {
        case .sameTurnConfirm: return .sameTurnConfirm
        case .nextTurnConfirm: return .nextTurnConfirm
        case .badgeOnly: return .badgeOnly
        case .unknown: return .unknown
        }
    }

    private func makeDailyReadViewModel(
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

    private func estimatedReadingSeconds(for body: String) -> Int {
        // Approximate: average English reading speed ~200 words per minute.
        let words = body
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        let seconds = Int((Double(words) / 200.0) * 60.0)
        return max(seconds, 30)
    }

    private func followReadPhaseLabel(_ phase: FollowReadPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .recording: return "recording"
        case .submitting: return "submitting"
        case .recorded: return "recorded"
        case let .failed(message): return "failed(\(message))"
        }
    }

    private var workbenchRoot: some View {
        WorkbenchHomeView(
            model: makeWorkbenchHomeViewModel(),
            onModuleTapped: openWorkbenchModule,
            onRetryTapped: {
                store.dispatch(.lifecycle(.appLaunched))
            }
        )
    }

    private func makeWorkbenchHomeViewModel() -> WorkbenchHomeViewModel {
        let modules = store.state.workspace.availableModules.map { descriptor in
            WorkbenchHomeViewModel.Module(
                id: descriptor.moduleName,
                title: moduleTitle(moduleName: descriptor.moduleName, entryRoute: descriptor.entryRoute),
                subtitle: moduleSubtitle(forEntryRoute: descriptor.entryRoute),
                systemImage: moduleIcon(forEntryRoute: descriptor.entryRoute),
                entryRoute: descriptor.entryRoute,
                kind: moduleKind(forEntryRoute: descriptor.entryRoute),
                isAvailable: AppRoute(entryRoute: descriptor.entryRoute) != nil
            )
        }

        let phase: WorkbenchHomeViewModel.Phase
        switch store.state.bootstrapStatus {
        case .idle, .loading:
            phase = .loading
        case .ready:
            phase = modules.isEmpty ? .empty : .ready
        case .failed:
            phase = .failed(message: store.state.lastErrorMessage)
        }

        return WorkbenchHomeViewModel(
            phase: phase,
            modules: modules,
            isOffline: !store.state.network.isConnected,
            activeModuleTitle: activeModuleTitle(from: store.state.workspace.activeSurface),
            highlightedBadge: store.state.workspace.highlightedBadge,
            badgeFeedCount: store.state.workspace.badgeFeedCount
        )
    }

    private func openWorkbenchModule(_ module: WorkbenchHomeViewModel.Module) {
        guard let action = AppRoute.workbenchNavigationAction(entryRoute: module.entryRoute) else {
            return
        }
        store.dispatch(.navigation(action))
    }

    private func activeModuleTitle(from surface: WorkspaceSurface) -> String? {
        switch surface {
        case .workbench:
            return nil
        case .speakingRoom:
            return "说的房间"
        case .review:
            return "回顾"
        }
    }

    private func moduleTitle(moduleName: String, entryRoute: String) -> String {
        switch entryRoute {
        case "/speaking-room":
            return "说的房间"
        case "/review":
            return "回顾"
        case "/daily-read":
            return "每日一读"
        case "/sessions":
            return "练习历史"
        default:
            return moduleName
        }
    }

    private func moduleSubtitle(forEntryRoute entryRoute: String) -> String {
        switch entryRoute {
        case "/speaking-room":
            return "进入实时口语练习，会话页使用全屏导航承载。"
        case "/review":
            return "查看评价、对照表达与炼句卡片，保持会话式全屏沉浸。"
        case "/daily-read":
            return "在工作台导航栈内进入阅读页，继续停留在当前 Tab。"
        case "/sessions":
            return "按时间回看每一场练习。列表按页加载，停留在当前 Tab。"
        default:
            return "该模块尚未接入当前 MVP 导航。"
        }
    }

    private func moduleIcon(forEntryRoute entryRoute: String) -> String {
        switch entryRoute {
        case "/speaking-room":
            return "mic.fill"
        case "/review":
            return "text.quote"
        case "/daily-read":
            return "book.fill"
        case "/sessions":
            return "clock.arrow.circlepath"
        default:
            return "square.grid.2x2"
        }
    }

    private func moduleKind(forEntryRoute entryRoute: String) -> WorkbenchHomeViewModel.Module.Kind {
        switch entryRoute {
        case "/speaking-room":
            return .speakingRoom
        case "/review":
            return .review
        case "/daily-read":
            return .dailyRead
        case "/sessions":
            return .sessionHistory
        default:
            return .unsupported
        }
    }

    private func closeSpeakingRoom() {
        if store.state.speakingRoom.phase != .idle && store.state.speakingRoom.phase != .ended {
            store.dispatch(.speakingRoom(.session(.endTap)))
        }
        dismissWorkbenchModal()
    }

    private func restartOrStartSpeakingSession() {
        // SpeechSessionMachine only starts from `.idle`; ended/failed surfaces
        // expose "重新开始/重试", so reset the session snapshot first without
        // touching the frozen machine itself.
        let phase = store.state.speakingRoom.phase
        if phase == .ended || phase == .failed {
            store.dispatch(.speakingRoom(.applySession(.initial)))
        }
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
    }

    private func dismissWorkbenchModal() {
        store.dispatch(.navigation(.workbench(.dismiss)))
    }
}

#Preview {
    HostRootView(store: AppStoreFactory.make())
}
