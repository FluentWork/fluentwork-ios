import Testing
@testable import FluentWorkUI

@Test func workbenchLoadingStateShowsBootstrapMessage() {
    let model = WorkbenchHomeViewModel(phase: .loading)

    #expect(model.statusTitle == "正在准备工作台")
    #expect(model.statusDetail == "正在同步启动配置和可见模块。")
    #expect(model.showsRetryAction == false)
}

@Test func workbenchFailureStateShowsRetryAction() {
    let model = WorkbenchHomeViewModel(
        phase: .failed(message: "bootstrap timeout")
    )

    #expect(model.statusTitle == "工作台加载失败")
    #expect(model.statusDetail == "bootstrap timeout")
    #expect(model.showsRetryAction == true)
}

@Test func workbenchModulePreservesNavigationMetadata() {
    let module = WorkbenchHomeViewModel.Module(
        id: "SpeakingRoom",
        title: "说的房间",
        subtitle: "进入实时口语练习，会话页使用全屏导航承载。",
        systemImage: "mic.fill",
        entryRoute: "/speaking-room",
        kind: .speakingRoom
    )

    #expect(module.entryRoute == "/speaking-room")
    #expect(module.kind == .speakingRoom)
    #expect(module.isAvailable == true)
}
