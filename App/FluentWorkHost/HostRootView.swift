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
                Text("语料库（占位）")
                    .foregroundStyle(.secondary)
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
            Text("说的房间（骨架）\(sessionID.map { " · \($0)" } ?? "")")
                .navigationTitle("说的房间")
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
                }
            )
        }
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
                anchorUserSaid: $0.anchorUserSaid
            )
        } ?? []

        return ReviewViewModel(
            phase: phase,
            overview: overview,
            transcript: transcript,
            dualColumn: dualColumn,
            refineCards: refineCards,
            errorMessage: state.lastErrorMessage
        )
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
            }

            Section("Feature Flags") {
                LabeledContent("Speaking Room", value: speakingRoomFlagEnabled ? "on" : "off")
                LabeledContent("Workspace Review", value: workspaceReviewFlagEnabled ? "on" : "off")
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
                        store.dispatch(.speakingRoom(.badgeHit("表达自然")))
                    }
                }
                .buttonStyle(.bordered)

                Button("Simulate Transcript") {
                    store.dispatch(.speakingRoom(.userSpeechCaptured("你好，FluentWork")))
                }
            }
        }
        .navigationTitle("FluentWork Host")
    }
}

#Preview {
    HostRootView()
}
