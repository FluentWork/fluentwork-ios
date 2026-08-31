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
        ResolverBackedBootstrapClient(
            resolver: FeatureFlagResolverFactory.makeFirstWaveResolver(),
            preferredSurface: .speakingRoom
        )
    }
    return container
}

@MainActor
private func waitForBootstrap(
    _ store: Store<AppState, AppAction>,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async {
    let step: UInt64 = 20_000_000
    var waited: UInt64 = 0
    while waited < timeoutNanoseconds {
        switch store.state.bootstrapStatus {
        case .ready, .failed:
            return
        case .idle, .loading:
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
    }
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

@Test func pluginCatalogEntryRoutesAlignWithAppRoute() {
    let catalog = FeaturePluginCatalog.firstWave
    for descriptor in catalog {
        switch descriptor.feature {
        case .speakingRoom, .workspaceReview, .dailyRead:
            #expect(AppRoute(entryRoute: descriptor.entryRoute) != nil)
        default:
            #expect(AppRoute(entryRoute: descriptor.entryRoute) == nil)
        }
    }
}

/// Store-level end-to-end: launch → resolver bootstrap → flag/plugin projection → navigate.
@MainActor
@Test func launchBootstrapsFlagsThenPresentsSpeakingRoom() async {
    let container = makeIsolatedLaunchContainer()
    let store = AppStoreFactory.make(container: container)

    store.dispatch(.lifecycle(.appLaunched))
    await waitForBootstrap(store)

    #expect(
        store.state.bootstrapStatus == .ready,
        "bootstrap failed: \(store.state.lastErrorMessage ?? "nil")"
    )
    #expect(store.state.featureFlags.isRemoteLoaded)
    #expect(store.state.featureFlags.isEnabled(.speakingRoom))
    #expect(store.state.speakingRoom.isBootstrapReady)
    #expect(store.state.network.isConnected)
    #expect(
        store.state.workspace.availableModules.map(\.moduleName) == ["SpeakingRoom", "Review", "DailyRead"]
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
@Test func launchThenSwitchTabKeepsIndependentStacks() async {
    let container = makeIsolatedLaunchContainer()
    let store = AppStoreFactory.make(container: container)

    store.dispatch(.lifecycle(.appLaunched))
    await waitForBootstrap(store)

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
