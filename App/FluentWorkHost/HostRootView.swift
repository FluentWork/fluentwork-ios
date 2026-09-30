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
        // Flag write-back lives here so it still runs if the room destination
        // identity flickers. The *dialog* must not: HostRootView presents the
        // speaking room as a fullScreenCover, and a second presentation from
        // this same presenter dismisses that cover (TTS keeps playing).
        .onChange(of: store.state.speakingRoom.phase) { _, phase in
            showsEndSessionConfirmation = phase.presentingEndSessionConfirmation(showsEndSessionConfirmation)
        }
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case let .speakingRoom(sessionID):
            // 投影只算一次。
            //
            // 以前这里调了三次 `makeSpeakingRoomViewModel(from:)` —— 一次给视图、另两次是
            // 在回调里为了读 `startTapIntent` / `stopTapIntent` 又重新算了一遍。同一份映射
            // 每帧跑三遍本身是浪费，更要紧的是：**回调执行时读的不是屏幕上那一份**，而是
            // 那一刻重新算出来的另一份。把模型提到前面，两边读的就是同一个值。
            let room = SpeakingRoomViewModel.make(
                from: store.state.speakingRoom,
                usesAutoVAD: store.state.usesVoiceVadAuto
            )
            ZStack(alignment: .top) {
                SpeakingRoomView(
                    model: room,
                    onStartTapped: {
                        switch room.startTapIntent {
                        case .startSession:
                            restartOrStartSpeakingSession()
                        case .beginTurn:
                            store.dispatch(.speakingRoom(.manualSpeechBegin))
                        case .none:
                            break
                        }
                    },
                    onStopTapped: {
                        switch room.stopTapIntent {
                        case .endTurn:
                            store.dispatch(.speakingRoom(.manualSpeechEnd))
                        case .endSession:
                            store.dispatch(.speakingRoom(.session(.endTap)))
                        case .none:
                            break
                        }
                    },
                    onRescueHintTapped: {
                        store.dispatch(.speakingRoom(.rescueHintTapped))
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
            // Alert wraps the ZStack *before* the phase-dependent bottom bar.
            // confirmationDialog after `safeAreaInset` was rebuilt on `.ended`
            // and flashed a second dialog that auto-dismissed.
            .alert("结束这次练习？", isPresented: $showsEndSessionConfirmation) {
                Button("确定", role: .destructive) {
                    showsEndSessionConfirmation = false
                    store.dispatch(.speakingRoom(.session(.endTap)))
                }
                Button("取消", role: .cancel) {
                    showsEndSessionConfirmation = false
                    store.dispatch(.speakingRoom(.session(.endSessionConfirmCancelled)))
                }
            } message: {
                Text("会话会结束并生成回顾，本轮要点会保留。")
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
                // A plain entry from the workbench passes nil and no seeding,
                // which is what makes it a *fresh* room: it clears whatever the
                // last visit left on screen.
                store.dispatch(.speakingRoom(.enterRoom(
                    continueFrom: sessionID,
                    seeding: store.state.sessionHistory.detail.detail?.utterances ?? []
                )))
            }
        case let .review(sessionID):
            let effectiveSessionID = sessionID ?? store.state.speakingRoom.lastSessionID
            ReviewRootView(
                model: ReviewViewModel.make(from: store.state.review),
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
                model: DailyReadViewModel.make(
                    from: store.state.dailyRead,
                    isOffline: !store.state.network.isConnected
                ),
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
                model: SessionHistoryViewModel.make(
                    from: store.state.sessionHistory,
                    // 「现在」由调用方给：投影里读 `Date()` 会让「今天/昨天」这三档文案
                    // 在任何判据里都不可重现。
                    now: Date()
                ),
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
                model: SessionDetailViewModel.make(
                    from: store.state.sessionHistory.detail,
                    now: Date()
                ),
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
                store.dispatch(.speakingRoom(.session(.endSessionConfirmShown)))
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
            // Alert is on the ZStack, before this bar. Opening pauses TTS;
            // 确定 ends the session; 取消 resumes.
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
        showsEndSessionConfirmation = false
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
    HostRootView(store: AppStoreFactory.makeShared())
}
