import FluentWorkCore
import SwiftUI
import FluentWorkUI

@MainActor
struct HostRootView: View {
    @State private var store = AppStoreFactory.make()
    @State private var didLaunch = false

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
                        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
                    },
                    onStopTapped: {
                        store.dispatch(.speakingRoom(.session(.endTap)))
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
            .onAppear { _ = sessionID }
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
        }
    }

    @ViewBuilder
    private var speakingRoomBottomBar: some View {
        switch store.state.speakingRoom.phase {
        case .idle, .failed:
            EmptyView()
        case .ended:
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
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        case .connecting, .recording, .waitingUser, .processing, .aiSpeaking, .degradedText:
            Button {
                store.dispatch(.speakingRoom(.session(.endTap)))
            } label: {
                Label("结束本轮", systemImage: "stop.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
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
            liveTranscript: state.liveTranscript,
            lastBadge: state.lastBadge,
            badgeHits: state.badgeHits,
            failureReason: state.failureReason
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

    private func dismissWorkbenchModal() {
        store.dispatch(.navigation(.workbench(.dismiss)))
    }
}

#Preview {
    HostRootView()
}
