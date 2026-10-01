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
            flashRoot: { flashTestPlaceholder },
            corpusRoot: {
                CorpusRootView(
                    model: CorpusViewModel.make(from: store.state.corpus),
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
                    },
                    onSceneFilterChanged: { scene in
                        store.dispatch(.corpus(.sceneFilterChanged(scene)))
                    },
                    onFunctionFilterChanged: { function in
                        store.dispatch(.corpus(.functionFilterChanged(function)))
                    },
                    onStartPractice: {
                        // 稿子 屏 08 的空态主按钮是「去练习」。它指向的是**开始一次练习**，
                        // 而那件事今天住在工作台（创建弹层的入口在那儿）。所以这一下是切 Tab，
                        // 不是把弹层从这里掀起来 —— 弹层属于工作台那条栈，从语料库掀会盖在错的地方。
                        store.dispatch(.navigation(.selectTab(.workbench)))
                    }
                )
            },
            settingsRoot: {
                SettingsRootView(
                    model: SettingsViewModel.make(
                        from: store.state.featureFlags,
                        // 版本号是 app 层的事实：投影里读 `Bundle.main` 会在测试进程里读到
                        // 测试 runner 的 bundle —— 恰好是你想核对版本的那一处读到错的那份。
                        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ),
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
            // **练完落到回顾页**（稿子 屏 04：「首次体验的 wow moment 承载页」）。
            // 从前这一步是房间底栏上的「查看回顾」按钮 —— 而那条底栏不在稿子里
            // （稿子 屏 02/03 只有顶部栏与说话键那一区）。去掉按钮就少了唯一的入口，
            // 所以改成「会话结束 ⇒ 回顾自己出现」，与稿子的叙事一致：
            // 练完就该看到这一轮学到了什么。没有 sessionID 时不跳（那时回顾也没东西可读）。
            if phase == .ended, store.state.speakingRoom.lastSessionID != nil {
                openReviewForLastSession()
            }
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
                usesAutoVAD: store.state.usesVoiceVadAuto,
                // 场景与「标准/迷你」是**创建练习那一屏**定下来的：房间只消费，不自己判断。
                creation: store.state.createPractice.pendingCreation
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
                    onClose: {
                        // 顶部栏左边的返回（稿子 屏 02 的 `[app-icon-btn]`）。
                        // 从前这一下是宿主盖在页面上的悬浮 ✕ —— 它会压住顶部栏的第一行
                        // （回顾页那边已经栽过一次），所以退回按钮收进这一屏自己。
                        closeSpeakingRoom()
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
                    }
                )
                .navigationTitle("说的房间")

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BadgeFeedbackOverlay(
                        model: BadgeFeedbackViewModel.make(
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
            // 稿子 屏 02/03 的房间**没有底部栏**：所有动作都在顶部栏（返回 / 结束本轮）与
            // 说话键那一区（状态行 / 浮层 / 键 / 安抚句）。原来那条红「结束练习」底栏
            // 是自造的 —— 全仓搜过稿子，`结束练习`／`结束这次`／`结束会话` **零命中**，
            // 只有 4 处 `结束本轮`。所以整条底栏（含 `.ended` 那半）去掉。
            //
            // 「练完之后去哪」不靠底栏上的按钮，靠**练完自动落到回顾页**（见外层那条
            // `onChange(of: speakingRoom.phase)`）—— 稿子 屏 04 自称「首次体验的 wow moment
            // 承载页」，它本来就是紧跟一次练习出现的那一屏。
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
                },
                onDiscardRefineCard: { cardID in
                    store.dispatch(.review(.discardRefineCardTapped(cardID: cardID)))
                },
                onRestoreRefineCard: { cardID in
                    store.dispatch(.review(.restoreRefineCardTapped(cardID: cardID)))
                },
                onEditRefineCard: { cardID, field, value in
                    store.dispatch(
                        .review(.refineCardEditChanged(cardID: cardID, field: field, value: value))
                    )
                },
                onRevertRefineCardEdits: { cardID in
                    store.dispatch(.review(.refineCardEditReverted(cardID: cardID)))
                },
                onPracticeAgain: {
                    // 稿子 屏 04 的「再来一轮」：关掉回顾，回到**创建练习**弹层再选一次。
                    // 不直接进房间 —— 那一屏存在的理由就是「今天练什么」由学员选，
                    // 绕开它等于把上次的选择当成这次的选择。
                    store.dispatch(.navigation(.workbench(.dismiss)))
                    store.dispatch(
                        .navigation(.workbench(.present(.createPractice, style: .sheet)))
                    )
                },
                onDone: {
                    dismissWorkbenchModal()
                },
                onClose: {
                    dismissWorkbenchModal()
                }
            )
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
        case .drill:
            // 这条路今天走不到：闪测的模块入口是 `.selectTab(.flashTest)`
            // （`AppRoute.drill.defaultWorkbenchNavigationAction`），它不往栈里压页。
            // 但 `AppRoute` 是 `Codable` —— 深链与状态恢复都可能构造出它，
            // 那时一片空白比一句占位难查得多，所以目的地写在 Tab 根同一个视图上。
            flashTestPlaceholder
        case .topicCards:
            TopicCardsRootView(
                model: TopicCardsViewModel.make(from: store.state.topic),
                onAppear: {
                    store.dispatch(.topic(.appear))
                },
                onRefresh: {
                    store.dispatch(.topic(.refreshRequested))
                },
                onReflectionChanged: { cardID, value in
                    store.dispatch(
                        .topic(.checkinDraftReflectionChanged(cardID: cardID, value: value))
                    )
                },
                onToggleBlock: { cardID, blockID in
                    store.dispatch(
                        .topic(.checkinDraftBlockToggled(cardID: cardID, blockID: blockID))
                    )
                },
                onDiscardDraft: { cardID in
                    store.dispatch(.topic(.checkinDraftDiscarded(cardID: cardID)))
                },
                onCheckIn: { cardID in
                    store.dispatch(.topic(.checkinTapped(cardID: cardID)))
                },
                onDismiss: { cardID, reason in
                    store.dispatch(.topic(.dismissTapped(cardID: cardID, reason: reason)))
                }
            )
        case .createPractice:
            // 屏 11（底部弹层）。呈现样式由 `AppRoute.defaultWorkbenchNavigationAction` 定，
            // 这里只是它的内容 —— 视图不决定自己是弹层还是全屏页。
            CreatePracticeSheet(
                model: CreatePracticeViewModel.make(from: store.state.createPractice),
                onInputChanged: { input in
                    store.dispatch(.createPractice(.inputChanged(input)))
                },
                onDraftChanged: { text in
                    store.dispatch(.createPractice(.draftChanged(text)))
                },
                onLengthChanged: { length in
                    store.dispatch(.createPractice(.lengthChanged(length)))
                },
                onSubmit: {
                    store.dispatch(.createPractice(.submitTapped))
                },
                onClose: {
                    store.dispatch(.navigation(.workbench(.dismiss)))
                }
            )
        }
    }

    /// 闪测页 —— ④ 逐屏之前它是占位。
    ///
    /// 底部 Tab 2 的根与 `.drill` 这条路用的是**同一个视图**：同一个功能在两处出现时，
    /// 两处渲染出两样东西，本身就是一条误导。
    private var flashTestPlaceholder: some View {
        placeholderScreen(
            title: "闪测（占位）",
            detail: "训练卡流、判定与申诉、结算都还没落地。"
        )
    }

    private func placeholderScreen(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var workbenchRoot: some View {
        VStack(spacing: 0) {
            startPracticeEntry
            WorkbenchHomeView(
                model: WorkbenchHomeViewModel.make(
                    from: store.state.workspace,
                    bootstrapStatus: store.state.bootstrapStatus,
                    lastErrorMessage: store.state.lastErrorMessage,
                    isOffline: !store.state.network.isConnected
                ),
                onModuleTapped: openWorkbenchModule,
                onRetryTapped: {
                    store.dispatch(.lifecycle(.appLaunched))
                }
            )
        }
    }

    /// 屏 11 的入口。
    ///
    /// 稿子把它画在 **屏 01 的「今日入口卡」**里（最大卡片、品牌色底、文案动态生成，
    /// 两个动作：开始新练习 / 继续上次）。屏 01 尚未还原，所以这里先放那张卡的**最小形态** ——
    /// 只留「开始新练习」这一半，「继续上次」等会话标题字段到位（见 `ui-rebuild-plan.md` §2）。
    /// 屏 01 那一票落地时，这个入口应当**被收进那张卡**，而不是在它旁边再留一个。
    private var startPracticeEntry: some View {
        Button {
            store.dispatch(
                .navigation(.workbench(.present(.createPractice, style: .sheet)))
            )
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
                Text("今天想练什么")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Text("一句话描述、粘贴素材，或用预置场景直接开始")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textPrimary.opacity(0.8))
                    .multilineTextAlignment(.leading)
                Text("开始新练习")
                    .font(DesignTokens.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .padding(.horizontal, DesignTokens.Spacing.s4)
                    .frame(minHeight: DesignTokens.Component.minHitTarget)
                    .background(
                        DesignTokens.Color.brandStrong,
                        in: RoundedRectangle(
                            cornerRadius: DesignTokens.Radius.card,
                            style: .continuous
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.s4)
            .background(
                DesignTokens.Color.brand,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
        .padding(.top, DesignTokens.Spacing.s4)
        .accessibilityIdentifier("workbench.startPractice")
    }

    private func openWorkbenchModule(_ module: WorkbenchHomeViewModel.Module) {
        guard let action = AppRoute.workbenchNavigationAction(entryRoute: module.entryRoute) else {
            return
        }
        store.dispatch(.navigation(action))
    }

    private func closeSpeakingRoom() {
        showsEndSessionConfirmation = false
        // **一次正在进行中的练习，不能因为一下误触就没了** —— 从前这条保护挂在底栏那颗
        // 红「结束练习」上，而那条底栏不在稿子里（稿子 屏 02/03 只有顶部栏与说话键那一区）。
        // 现在顶部栏左边的返回键是唯一的退出入口，于是这条保护跟着它走：
        // 会话在跑就问一句，没在跑就直接退出。
        if store.state.speakingRoom.phase != .idle && store.state.speakingRoom.phase != .ended {
            store.dispatch(.speakingRoom(.session(.endSessionConfirmShown)))
            showsEndSessionConfirmation = true
            return
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
