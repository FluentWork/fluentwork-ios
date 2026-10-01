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
                // **深色优先**：09-26 稿的一句自述是「浅色主题未出稿；深色为默认」，
                // 而整套令牌（`DesignTokens.Hex` 那一片）也只在深色底上成立。
                // （不在这里写具体色值：`hexColorLiteralsLiveOnlyInDesignTokens` 连注释里的
                // 十六进制也算越界 —— 那条守卫是对的，令牌只有一张表。）
                // 不写这一句的话，系统的浅色外观会渗进来 —— 最明显的一处是输入框的占位文字：
                // 它走的是系统 secondary 色，在深色令牌底上几乎看不见（截图里抓到的）。
                .preferredColorScheme(.dark)
            #if os(iOS)
            .onChange(of: scenePhase) { _, newPhase in
                dispatchScenePhase(newPhase)
            }
            #endif
            #if DEBUG
            // 真机场景驱动（F6 的验收工具）。没设 `FW_SCENARIO` 时它立刻返回、什么都不做。
            // 它派的是**视图自己会派的那几条 action**，见 `DeviceScenarioDriver` 的注释。
            .task { await DeviceScenarioDriver.runIfConfigured(store: store) }
            // 看版式用的摆位（`FW_SCREEN`）。同样没设变量就什么都不做 ——
            // 它只把某一屏放到前台，不跑流程。见 `DebugScreenPreview`。
            .task { await DebugScreenPreview.applyIfConfigured(store: store) }
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
