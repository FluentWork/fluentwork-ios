import FluentWorkCore
import SwiftUI

@main
@MainActor
struct FluentWorkHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStoreFactory.make()

    var body: some Scene {
        WindowGroup {
            HostRootView(store: store)
            #if os(iOS)
            .onChange(of: scenePhase) { _, newPhase in
                dispatchScenePhase(newPhase)
            }
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
