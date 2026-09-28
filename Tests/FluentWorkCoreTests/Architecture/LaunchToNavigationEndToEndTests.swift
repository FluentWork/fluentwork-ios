import FactoryKit
import FluentWorkFeatureFlags
import FluentWorkNetworking
import FluentWorkPluginSupport
import Testing
import TGNavigationStack
import TGReduxKit
@testable import FluentWorkCore

@MainActor
private func makeIsolatedLaunchContainer() -> Container {
    let container = Container()
    container.networkMonitor.register {
        StubNetworkMonitor(snapshot: .connected)
    }
    container.bootstrapClient.register {
        StaticBootstrapClient(
            snapshot: BootstrapSnapshot(
                featureFlags: .firstWave,
                preferredSurface: .speakingRoom
            )
        )
    }
    return container
}

@Test func appRouteBridgesPluginEntryRoutes() {
    #expect(AppRoute.speakingRoom(sessionID: nil).entryRoute == "/speaking-room")
    #expect(AppRoute.review(sessionID: "r1").entryRoute == "/review")
    #expect(AppRoute.dailyRead(sessionID: nil).entryRoute == "/daily-read")
    #expect(AppRoute(entryRoute: "/speaking-room") == .speakingRoom(sessionID: nil))
    #expect(AppRoute(entryRoute: "/review", sessionID: "abc") == .review(sessionID: "abc"))
    #expect(AppRoute(entryRoute: "/daily-read", sessionID: nil) == .dailyRead(sessionID: nil))
    #expect(AppRoute(entryRoute: "/drill") == nil)
}

@Test func appRouteBuildsWorkbenchNavigationActions() {
    #expect(
        AppRoute.speakingRoom(sessionID: nil).defaultWorkbenchNavigationAction
            == .workbench(.present(.speakingRoom(sessionID: nil), style: .fullScreenCover))
    )
    #expect(
        AppRoute.review(sessionID: "review-1").defaultWorkbenchNavigationAction
            == .workbench(.present(.review(sessionID: "review-1"), style: .fullScreenCover))
    )
    #expect(
        AppRoute.dailyRead(sessionID: "daily-1").defaultWorkbenchNavigationAction
            == .workbench(.push(.dailyRead(sessionID: "daily-1")))
    )
    #expect(
        AppRoute.workbenchNavigationAction(entryRoute: "/speaking-room", sessionID: "room-1")
            == .workbench(.present(.speakingRoom(sessionID: "room-1"), style: .fullScreenCover))
    )
    #expect(
        AppRoute.workbenchNavigationAction(entryRoute: "/daily-read", sessionID: "daily-2")
            == .workbench(.push(.dailyRead(sessionID: "daily-2")))
    )
    #expect(AppRoute.workbenchNavigationAction(entryRoute: "/drill") == nil)
}

@Test func pluginCatalogEntryRoutesAlignWithAppRoute() {
    let catalog = FeaturePluginCatalog.firstWave
    for descriptor in catalog {
        switch descriptor.feature {
        case .speakingRoom, .workspaceReview, .dailyRead, .sessionHistory:
            #expect(AppRoute(entryRoute: descriptor.entryRoute) != nil)
        default:
            #expect(AppRoute(entryRoute: descriptor.entryRoute) == nil)
        }
    }
}

/// Store-level end-to-end: launch → resolver bootstrap → flag/plugin projection → navigate.
@MainActor
@Test func launchBootstrapsFlagsThenPresentsSpeakingRoom() async throws {
    let container = makeIsolatedLaunchContainer()
    let store = AppStoreFactory.make(container: container)

    store.dispatch(.lifecycle(.appLaunched))
    try await waitForBootstrap(store)

    #expect(
        store.state.bootstrapStatus == .ready,
        "bootstrap failed: \(store.state.lastErrorMessage ?? "nil")"
    )
    #expect(store.state.featureFlags.isRemoteLoaded)
    #expect(store.state.featureFlags.isEnabled(.speakingRoom))
    #expect(store.state.speakingRoom.isBootstrapReady)
    #expect(store.state.network.isConnected)
    #expect(
        store.state.workspace.availableModules.map(\.moduleName)
            == ["SpeakingRoom", "Review", "DailyRead", "SessionHistory"]
    )

    let speakingEntry = store.state.workspace.availableModules.first {
        $0.moduleName == "SpeakingRoom"
    }
    #expect(speakingEntry != nil)

    guard let speakingEntry,
          let route = AppRoute(entryRoute: speakingEntry.entryRoute, sessionID: "session-e2e")
    else {
        return
    }

    store.dispatch(
        .navigation(
            .workbench(.present(route, style: .fullScreenCover))
        )
    )

    #expect(store.state.navigation.selectedTab == .workbench)
    #expect(store.state.navigation.workbench.presentedRoute == route)
    #expect(store.state.navigation.workbench.presentationStyle == .fullScreenCover)

    store.dispatch(.navigation(.workbench(.dismiss)))
    #expect(store.state.navigation.workbench.presentedRoute == nil)
    #expect(store.state.navigation.workbench.presentationStyle == nil)
}

@MainActor
@Test func launchThenSwitchTabKeepsIndependentStacks() async throws {
    let container = makeIsolatedLaunchContainer()
    let store = AppStoreFactory.make(container: container)

    store.dispatch(.lifecycle(.appLaunched))
    try await waitForBootstrap(store)

    #expect(
        store.state.bootstrapStatus == .ready,
        "bootstrap failed: \(store.state.lastErrorMessage ?? "nil")"
    )

    store.dispatch(
        .navigation(.workbench(.push(.review(sessionID: "on-workbench"))))
    )
    store.dispatch(.navigation(.selectTab(.flashTest)))
    store.dispatch(
        .navigation(.flashTest(.push(.speakingRoom(sessionID: "on-flash"))))
    )

    #expect(store.state.navigation.selectedTab == .flashTest)
    #expect(store.state.navigation.workbench.path == [.review(sessionID: "on-workbench")])
    #expect(store.state.navigation.flashTest.path == [.speakingRoom(sessionID: "on-flash")])
    #expect(store.state.navigation.corpus.path.isEmpty)
}

@MainActor
@Test func speakingRoomModalCanEndSessionThenDismiss() async throws {
    let initial = AppState(
        speakingRoom: SpeakingRoomState(
            phase: .recording,
            liveTranscript: "hello",
            isBootstrapReady: true
        ),
        navigation: AppNavigationState(
            workbench: NavigationState(
                presentedRoute: .speakingRoom(sessionID: "room-active"),
                presentationStyle: .fullScreenCover
            )
        )
    )
    let container = Container()
    container.reset()
    let store = AppStoreFactory.make(container: container, initialState: initial)

    store.dispatch(.speakingRoom(.session(.endTap)))
    try await waitUntil(label: "说的房间进入 .ended") {
        store.state.speakingRoom.phase == .ended
    }
    #expect(store.state.speakingRoom.phase == .ended)

    store.dispatch(.navigation(.workbench(.dismiss)))
    #expect(store.state.navigation.workbench.presentedRoute == nil)
    #expect(store.state.navigation.workbench.presentationStyle == nil)
}

@MainActor
@Test func reviewModalCanDismissBackToWorkbench() {
    let initial = AppState(
        navigation: AppNavigationState(
            workbench: NavigationState(
                presentedRoute: .review(sessionID: "review-active"),
                presentationStyle: .fullScreenCover
            )
        )
    )
    let container = Container()
    container.reset()
    let store = AppStoreFactory.make(container: container, initialState: initial)

    store.dispatch(.navigation(.workbench(.dismiss)))

    #expect(store.state.navigation.workbench.presentedRoute == nil)
    #expect(store.state.navigation.workbench.presentationStyle == nil)
}
