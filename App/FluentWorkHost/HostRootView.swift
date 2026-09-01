import FluentWorkCore
import SwiftUI
import FluentWorkUI

@MainActor
struct HostRootView: View {
    @State private var store = AppStoreFactory.make()
    @State private var didLaunch = false

    private var speakingRoomFlagEnabled: Bool {
        store.state.featureFlags.isEnabled(.speakingRoom)
    }

    private var workspaceReviewFlagEnabled: Bool {
        store.state.featureFlags.isEnabled(.workspaceReview)
    }

    private var dailyReadFlagEnabled: Bool {
        store.state.featureFlags.isEnabled(.dailyRead)
    }

    var body: some View {
        AppRootTabView(
            navigation: store.state.navigation,
            dispatch: { store.dispatch($0) },
            workbenchRoot: { debugRootList },
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
            .onAppear { _ = sessionID }
        case let .review(sessionID):
            ReviewRootView(
                model: makeReviewViewModel(from: store.state.review),
                onAppear: {
                    store.dispatch(.review(.appear(sessionID: sessionID)))
                },
                onRetry: {
                    let targetSessionID = store.state.review.sessionID ?? sessionID
                    guard let targetSessionID, !targetSessionID.isEmpty else { return }
                    store.dispatch(.review(.loadRequested(sessionID: targetSessionID)))
                },
                onAcceptRefineCard: { cardID in
                    store.dispatch(.review(.acceptRefineCardTapped(cardID: cardID)))
                }
            )
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

    private var debugRootList: some View {
        List {
            Section("Bootstrap") {
                LabeledContent("Status", value: store.state.bootstrapStatus.rawValue)
                LabeledContent("Active Surface", value: store.state.workspace.activeSurface.rawValue)
                LabeledContent(
                    "Remote Loaded",
                    value: store.state.featureFlags.isRemoteLoaded ? "yes" : "no"
                )
                LabeledContent(
                    "Network",
                    value: store.state.network.isConnected ? "online" : "offline"
                )

                if let message = store.state.lastErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }

                Button("Trigger Bootstrap") {
                    store.dispatch(.lifecycle(.appLaunched))
                }
            }

            Section("Navigation") {
                Button("Present Speaking Room") {
                    store.dispatch(
                        .navigation(
                            .workbench(.present(.speakingRoom(sessionID: nil), style: .fullScreenCover))
                        )
                    )
                }
                .disabled(!speakingRoomFlagEnabled)

                Button("Present Review") {
                    store.dispatch(
                        .navigation(
                            .workbench(.present(.review(sessionID: nil), style: .fullScreenCover))
                        )
                    )
                }
                .disabled(!workspaceReviewFlagEnabled)

                Button("Present Daily Read") {
                    store.dispatch(
                        .navigation(
                            .workbench(.present(.dailyRead(sessionID: nil), style: .fullScreenCover))
                        )
                    )
                }
                .disabled(!dailyReadFlagEnabled)

                Button("切到语料库 Tab") {
                    store.dispatch(.navigation(.selectTab(.corpus)))
                }
            }

            Section("Feature Flags") {
                LabeledContent("Speaking Room", value: speakingRoomFlagEnabled ? "on" : "off")
                LabeledContent("Workspace Review", value: workspaceReviewFlagEnabled ? "on" : "off")
                LabeledContent("Daily Read", value: dailyReadFlagEnabled ? "on" : "off")
                LabeledContent(
                    "Local Override Count",
                    value: "\(store.state.featureFlags.localOverrides.count)"
                )

                Button(speakingRoomFlagEnabled ? "Disable Speaking Room" : "Enable Speaking Room") {
                    store.dispatch(
                        .featureFlags(
                            .setLocalOverride(
                                flag: .speakingRoom,
                                isEnabled: !speakingRoomFlagEnabled
                            )
                        )
                    )
                }

                Button(dailyReadFlagEnabled ? "Disable Daily Read" : "Enable Daily Read") {
                    store.dispatch(
                        .featureFlags(
                            .setLocalOverride(
                                flag: .dailyRead,
                                isEnabled: !dailyReadFlagEnabled
                            )
                        )
                    )
                }

                Button("Clear Local Overrides") {
                    store.dispatch(.featureFlags(.clearLocalOverrides))
                }
                .disabled(store.state.featureFlags.localOverrides.isEmpty)
            }

            Section("Workspace") {
                LabeledContent(
                    "Bootstrap Complete",
                    value: store.state.workspace.isBootstrapComplete ? "yes" : "no"
                )
                LabeledContent("Highlighted Badge", value: store.state.workspace.highlightedBadge ?? "-")
                LabeledContent("Badge Feed Count", value: "\(store.state.workspace.badgeFeedCount)")

                ForEach(store.state.workspace.availableModules) { module in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(module.moduleName)
                            .font(.headline)
                        Text(module.entryRoute)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Workbench") {
                        store.dispatch(.workspace(.activate(.workbench)))
                    }
                    Button("Speaking") {
                        store.dispatch(.workspace(.activate(.speakingRoom)))
                    }
                    Button("Review") {
                        store.dispatch(.workspace(.activate(.review)))
                    }
                }
                .buttonStyle(.bordered)
            }

            Section("Auth") {
                LabeledContent("Mode", value: store.state.auth.mode.rawValue)
                LabeledContent("User ID", value: store.state.auth.currentUserID ?? "-")
                LabeledContent(
                    "Pending Merge Device",
                    value: store.state.auth.pendingMergeDeviceID ?? "-"
                )

                HStack {
                    Button("Guest Sign In") {
                        store.dispatch(
                            .auth(.signedInAsGuest(userID: "guest-1", deviceID: "device-1"))
                        )
                    }

                    Button("Promote") {
                        store.dispatch(
                            .auth(.mergedIntoRegistered(userID: "user-42", deviceID: "device-1"))
                        )
                    }
                }
                .buttonStyle(.bordered)

                Button("🗑️ Clear Token (Dev)") {
                    Task {
                        do {
                            let storage = KeychainSecureStorage()
                            let tokens = SecureAuthTokenStore(
                                storage: storage,
                                idGenerator: SystemIDGenerator()
                            )
                            try tokens.clear()
                            print("[🔑 Token] Cleared all tokens from Keychain")
                        } catch {
                            print("[🔑 Token] Failed to clear: \(error)")
                        }
                    }
                }
                .foregroundStyle(.red)
            }

            Section("Corpus") {
                LabeledContent("Phase", value: store.state.corpus.phase.rawValue)
                LabeledContent("Total Blocks", value: "\(store.state.corpus.items.count)")
                LabeledContent("Visible Blocks", value: "\(store.state.corpus.visibleItems.count)")
                LabeledContent("Refreshing", value: store.state.corpus.isRefreshing ? "yes" : "no")
                LabeledContent("Replaying Outbox", value: store.state.corpus.isReplayingOutbox ? "yes" : "no")
                LabeledContent("Next Cursor", value: store.state.corpus.nextCursor ?? "-")
                LabeledContent("Sync Cursor", value: store.state.corpus.syncCursor ?? "-")
                LabeledContent("Outbox Count", value: "\(store.state.corpus.outbox.count)")

                if let message = store.state.corpus.lastErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Load Corpus") {
                        store.dispatch(.corpus(.appear))
                    }

                    Button("Refresh") {
                        store.dispatch(.corpus(.refreshRequested))
                    }
                }
                .buttonStyle(.bordered)
            }

            Section("Daily Read") {
                LabeledContent("Phase", value: store.state.dailyRead.phase.rawValue)
                LabeledContent("Has Article", value: store.state.dailyRead.dailyRead != nil ? "yes" : "no")
                LabeledContent("Gen Date", value: store.state.dailyRead.genDate ?? "-")
                LabeledContent("Audio Phase", value: store.state.dailyRead.audioPhase.rawValue)
                LabeledContent(
                    "Follow-Read Phase",
                    value: followReadPhaseLabel(store.state.dailyRead.followReadPhase)
                )
                LabeledContent("Has Follow Read", value: store.state.dailyRead.hasFollowRead ? "yes" : "no")

                if let message = store.state.dailyRead.lastErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Load Daily Read") {
                        store.dispatch(.dailyRead(.loadTriggered))
                    }

                    Button("Clear") {
                        store.dispatch(.dailyRead(.clear))
                    }
                }
                .buttonStyle(.bordered)
            }

            Section("Speaking Room") {
                LabeledContent("Phase", value: store.state.speakingRoom.phase.rawValue)
                LabeledContent(
                    "Bootstrap Ready",
                    value: store.state.speakingRoom.isBootstrapReady ? "yes" : "no"
                )
                LabeledContent("Transcript", value: store.state.speakingRoom.liveTranscript)
                LabeledContent("Last Badge", value: store.state.speakingRoom.lastBadge ?? "-")
                LabeledContent("Badge Hits", value: "\(store.state.speakingRoom.badgeHits)")

                if let failureReason = store.state.speakingRoom.failureReason {
                    Text(failureReason)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Start") {
                        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
                    }
                    Button("Socket Ready") {
                        store.dispatch(.speakingRoom(.session(.socketReady)))
                    }
                    Button("Badge Hit") {
                        store.dispatch(.speakingRoom(.badgeHit(badge: "表达自然")))
                    }
                }
                .buttonStyle(.bordered)

                Button("Simulate Transcript") {
                    store.dispatch(.speakingRoom(.userSpeechCaptured("你好，FluentWork")))
                }
            }

            Section("Badge Feedback (I11)") {
                LabeledContent(
                    "Total Entries",
                    value: "\(store.state.badgeFeedback.entries.count)"
                )
                LabeledContent(
                    "Visible Window",
                    value: String(format: "%.1fs", store.state.badgeFeedback.visibleWindowSeconds)
                )
                LabeledContent(
                    "Max Visible",
                    value: "\(store.state.badgeFeedback.maxVisibleEntries)"
                )

                HStack {
                    Button("Hit 表达自然") {
                        store.dispatch(
                            .badgeFeedback(
                                .ingest(
                                    badge: "表达自然",
                                    turnID: "host-1",
                                    tier: .nextTurnConfirm,
                                    at: Date()
                                )
                            )
                        )
                    }
                    Button("Hit 节奏稳定") {
                        store.dispatch(
                            .badgeFeedback(
                                .ingest(
                                    badge: "节奏稳定",
                                    turnID: "host-2",
                                    tier: .badgeOnly,
                                    at: Date()
                                )
                            )
                        )
                    }
                    Button("Hit 用词地道") {
                        store.dispatch(
                            .badgeFeedback(
                                .ingest(
                                    badge: "用词地道",
                                    turnID: "host-3",
                                    tier: .unknown,
                                    at: Date()
                                )
                            )
                        )
                    }
                }
                .buttonStyle(.bordered)

                Button("Tick (sweep)") {
                    store.dispatch(.badgeFeedback(.tick(at: Date())))
                }
                Button("Clear Feed") {
                    store.dispatch(.badgeFeedback(.clear))
                }
                .disabled(store.state.badgeFeedback.entries.isEmpty)
            }
        }
        .navigationTitle("FluentWork Host")
    }
}

#Preview {
    HostRootView()
}
