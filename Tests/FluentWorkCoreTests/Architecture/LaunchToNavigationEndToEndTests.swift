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

    // ③：闪测与话题卡从「目录里有、导航不认识」变成有目的地。
    #expect(AppRoute.drill.entryRoute == "/drill")
    #expect(AppRoute.topicCards.entryRoute == "/topic-cards")
    #expect(AppRoute(entryRoute: "/drill") == .drill)
    #expect(AppRoute(entryRoute: "/topic-cards") == .topicCards)

    // 补路由不是「什么都收」：没听过的路径仍然是 `nil`。
    // 少了这一半，把 `init?` 改成永远返回某条路由也能全绿。
    #expect(AppRoute(entryRoute: "/shadowing") == nil)
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

    // 闪测这一条是**刻意的例外**，写死在这里当判据：它的家在底部 Tab 2（09-26 稿 §03：
    // 「Tab 2 · 闪测」「底部 Tab → 直接开始」1 次点击）。把它同时做成工作台栈里的一页，
    // 同一个屏幕就会有两条进入路径、两种行为 —— 所以这里把 Tab 切过去，而不是 push 一页。
    #expect(AppRoute.drill.defaultWorkbenchNavigationAction == .selectTab(.flashTest))
    #expect(
        AppRoute.workbenchNavigationAction(entryRoute: "/drill") == .selectTab(.flashTest)
    )

    // 话题建议页与每日一读同类：工作台导航栈内的页面。
    #expect(
        AppRoute.topicCards.defaultWorkbenchNavigationAction
            == .workbench(.push(.topicCards))
    )
    #expect(
        AppRoute.workbenchNavigationAction(entryRoute: "/topic-cards")
            == .workbench(.push(.topicCards))
    )

    // 只有「没听过的路由」才拿不到动作。
    #expect(AppRoute.workbenchNavigationAction(entryRoute: "/shadowing") == nil)
}

/// 目录与路由的**一致性**：目录说「有这个模块」，路由说「点进去去哪」。
///
/// 两者不一致时的后果不是报错，是工作台上多出一个点了没反应的入口 ——
/// `WorkbenchHomeProjection` 拿 `AppRoute(entryRoute:)` 判「能不能点」，判的正是这一条。
/// 上一版把这条写成 `switch descriptor.feature` 只让 first-wave 四条通过，所以
/// **③ 加路由时它必然红** —— 那是内置的提醒物，不是障碍。
@Test func pluginCatalogEntryRoutesAlignWithAppRoute() {
    let catalog = FeaturePluginCatalog.firstWave
    #expect(catalog.count >= 6, "目录里只剩 \(catalog.count) 条 —— 下面的循环会因为没东西可查而空转")

    for descriptor in catalog {
        #expect(
            AppRoute(entryRoute: descriptor.entryRoute) != nil,
            """
            \(descriptor.moduleName)（\(descriptor.entryRoute)）在目录里，导航却不认识它 ——
            工作台上会多出一个点进去是空屏的入口。
            """
        )
        #expect(
            AppRoute.workbenchNavigationAction(entryRoute: descriptor.entryRoute) != nil,
            """
            \(descriptor.moduleName)（\(descriptor.entryRoute)）能解析成路由，却拿不到导航动作 ——
            工作台上那个模块按钮按下去不会有任何反应。
            """
        )
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
