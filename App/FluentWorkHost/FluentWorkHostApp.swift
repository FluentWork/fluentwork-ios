import FluentWorkCore
import SwiftUI

@main
@MainActor
struct FluentWorkHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStoreFactory.makeShared()

    var body: some Scene {
        WindowGroup {
            HostRootView(store: store)
            #if os(iOS)
            .onChange(of: scenePhase) { _, newPhase in
                dispatchScenePhase(newPhase)
            }
            #endif
            #if DEBUG
            // 真机场景驱动（F6 的验收工具）。没设 `FW_SCENARIO` 时它立刻返回、什么都不做。
            // 它派的是**视图自己会派的那几条 action**，见 `DeviceScenarioDriver` 的注释。
            .task { await DeviceScenarioDriver.runIfConfigured(store: store) }
            #endif
        }
    }

    private func dispatchScenePhase(_ phase: ScenePhase) {
        let kind: ScenePhaseKind
        switch phase {
        case .background:
            kind = .background
        case .active:
            kind = .active
        case .inactive:
            kind = .inactive
        @unknown default:
            kind = .unknown
        }

        guard let event = ScenePhaseSessionHandler.event(
            scenePhase: kind,
            sessionPhase: store.state.speakingRoom.phase
        ) else {
            return
        }
        store.dispatch(.speakingRoom(.session(event)))
    }
}
