import FluentWorkCore
import FluentWorkPluginSupport
import Testing

@testable import FluentWorkUI

/// `WorkbenchHomeViewModel.make(from:bootstrapStatus:lastErrorMessage:isOffline:)` —— 工作台的投影。
///
/// 这一份此前是 `HostRootView` 的 `private func`，而且它**直接读 `store.state`**（读
/// `bootstrapStatus` / `lastErrorMessage` / `network`）—— 签名上说它只要一个状态，实际要四个。
/// 搬出来之后那三个变成参数，跨状态依赖就写在类型上了。
@Suite("工作台的投影")
struct WorkbenchHomeProjectionTests {

    private func descriptor(module: String, route: String) -> FeaturePluginDescriptor {
        FeaturePluginDescriptor(feature: .speakingRoom, moduleName: module, entryRoute: route)
    }

    /// 已知模块各自的标题 / 副标题 / 图标 / 种类。
    ///
    /// 六张表放在一起断言，因为它们是同一件事的几张脸 —— 逐条挑一个测会让「某一行的图标写成了
    /// 另一行的」这种复制粘贴错误溜过去。
    @Test func 已知模块的四张表() {
        var workspace = WorkspaceState()
        workspace.availableModules = [
            descriptor(module: "speaking-room", route: "/speaking-room"),
            descriptor(module: "review", route: "/review"),
            descriptor(module: "daily-read", route: "/daily-read"),
            descriptor(module: "sessions", route: "/sessions"),
            descriptor(module: "drill", route: "/drill"),
            descriptor(module: "topic-cards", route: "/topic-cards"),
        ]

        let model = WorkbenchHomeViewModel.make(
            from: workspace,
            bootstrapStatus: .ready,
            lastErrorMessage: nil,
            isOffline: false
        )

        #expect(
            model.modules.map(\.title)
                == ["说的房间", "回顾", "每日一读", "练习历史", "闪测", "话题建议"]
        )
        #expect(
            model.modules.map(\.systemImage)
                == [
                    "mic.fill", "text.quote", "book.fill",
                    "clock.arrow.circlepath", "bolt.fill", "bubble.left.and.bubble.right.fill",
                ]
        )
        #expect(
            model.modules.map(\.kind)
                == [
                    .speakingRoom, .review, .dailyRead, .sessionHistory, .drill, .topicCards,
                ]
        )
        #expect(
            model.modules.map(\.id)
                == ["speaking-room", "review", "daily-read", "sessions", "drill", "topic-cards"]
        )
        #expect(
            model.modules.map(\.entryRoute)
                == ["/speaking-room", "/review", "/daily-read", "/sessions", "/drill", "/topic-cards"]
        )
        #expect(model.modules.allSatisfy { !$0.subtitle.isEmpty }, "有模块没有副标题")
    }

    /// 认不出的模块：标题用它**自己的名字**，种类是 `.unsupported`。
    ///
    /// 名字不许被折成一句通用的话 —— 后端把新模块注册进来时，屏幕上写着它的名字才是可读的信号，
    /// 而「未知模块」什么都不说明。
    @Test func 认不出的模块用自己的名字() {
        var workspace = WorkspaceState()
        workspace.availableModules = [descriptor(module: "shadowing", route: "/shadowing")]

        let model = WorkbenchHomeViewModel.make(
            from: workspace,
            bootstrapStatus: .ready,
            lastErrorMessage: nil,
            isOffline: false
        )

        let module = model.modules[0]
        #expect(module.title == "shadowing")
        #expect(module.kind == .unsupported)
        #expect(module.subtitle == "该模块尚未接入当前 MVP 导航。")
        #expect(module.systemImage == "square.grid.2x2")
    }

    /// **`isAvailable` 问的是「导航认不认这条路由」，不是「后端有没有这个能力」。**
    ///
    /// ③ 给 `/drill` 与 `/topic-cards` 补上了目的地，所以它们从这里起必须显示成**可用** ——
    /// 「目录里有模块」与「导航认识这条路径」是同一件事的两半，任何一半单独改动都会在这里红。
    /// （③ 之前这条判据断言的正好是相反的值，那正是它该起的作用。）
    ///
    /// 另一半是 `/shadowing`：导航不认识的路径仍然要显示成不可用 ——
    /// 一个点进去是空屏的入口，比一个明确不可用的入口更坏。
    @Test func 可不可用取决于导航认不认这条路由() {
        var workspace = WorkspaceState()
        workspace.availableModules = [
            descriptor(module: "speaking-room", route: "/speaking-room"),
            descriptor(module: "drill", route: "/drill"),
            descriptor(module: "topic-cards", route: "/topic-cards"),
            descriptor(module: "shadowing", route: "/shadowing"),
        ]

        let model = WorkbenchHomeViewModel.make(
            from: workspace,
            bootstrapStatus: .ready,
            lastErrorMessage: nil,
            isOffline: false
        )

        #expect(model.modules[0].isAvailable, "已知路由被标成了不可用")
        #expect(model.modules[1].isAvailable, "闪测已经有目的地了（③），却还显示成不可用")
        #expect(model.modules[2].isAvailable, "话题卡已经有目的地了（③），却还显示成不可用")
        #expect(model.modules[3].isAvailable == false, "导航不认识 /shadowing，却显示成可用")
    }

    /// 四个启动相位映成四种屏幕状态，其中 `.ready` **要分「有模块」与「一个都没有」**。
    ///
    /// 合成一个会让「加载完了但什么都没有」永远转圈 —— 两者的文案不同（「开始今天的练习」vs
    /// 「当前没有可用模块」）。
    @Test func 启动相位映成屏幕状态() {
        var empty = WorkspaceState()
        let noModules = WorkbenchHomeViewModel.make(
            from: empty,
            bootstrapStatus: .ready,
            lastErrorMessage: nil,
            isOffline: false
        )
        #expect(noModules.phase == .empty)

        var withModule = WorkspaceState()
        withModule.availableModules = [descriptor(module: "review", route: "/review")]
        #expect(
            WorkbenchHomeViewModel.make(
                from: withModule,
                bootstrapStatus: .ready,
                lastErrorMessage: nil,
                isOffline: false
            ).phase == .ready
        )

        for status: BootstrapStatus in [.idle, .loading] {
            #expect(
                WorkbenchHomeViewModel.make(
                    from: withModule,
                    bootstrapStatus: status,
                    lastErrorMessage: nil,
                    isOffline: false
                ).phase == .loading,
                "\(status) 应该还在加载中"
            )
        }

        #expect(
            WorkbenchHomeViewModel.make(
                from: empty,
                bootstrapStatus: .failed,
                lastErrorMessage: "后端不可达",
                isOffline: false
            ).phase == .failed(message: "后端不可达")
        )
        // 失败但没带原因：仍然是失败，只是原因为空 —— 不许降级成别的东西。
        #expect(
            WorkbenchHomeViewModel.make(
                from: empty,
                bootstrapStatus: .failed,
                lastErrorMessage: nil,
                isOffline: false
            ).phase == .failed(message: nil)
        )
    }

    /// 当前所在模块的标题：在工作台自己没有名字可报，在房间/回顾各有各的名字。
    @Test func 当前模块的标题() {
        func title(_ surface: WorkspaceSurface) -> String? {
            var workspace = WorkspaceState()
            workspace.activeSurface = surface
            return WorkbenchHomeViewModel.make(
                from: workspace,
                bootstrapStatus: .ready,
                lastErrorMessage: nil,
                isOffline: false
            ).activeModuleTitle
        }

        #expect(title(.workbench) == nil, "工作台本身没有「当前模块」可报")
        #expect(title(.speakingRoom) == "说的房间")
        #expect(title(.review) == "回顾")
    }

    /// 剩下三个维度直通：离线、高亮徽标、徽标计数。
    @Test func 离线与徽标三个维度直通() {
        var workspace = WorkspaceState()
        workspace.highlightedBadge = "ship it"
        workspace.badgeFeedCount = 7
        workspace.availableModules = [descriptor(module: "review", route: "/review")]

        let online = WorkbenchHomeViewModel.make(
            from: workspace,
            bootstrapStatus: .ready,
            lastErrorMessage: nil,
            isOffline: false
        )
        let offline = WorkbenchHomeViewModel.make(
            from: workspace,
            bootstrapStatus: .ready,
            lastErrorMessage: nil,
            isOffline: true
        )

        #expect(online.isOffline == false)
        #expect(offline.isOffline == true)
        #expect(online.highlightedBadge == "ship it")
        #expect(online.badgeFeedCount == 7)
        // 除离线标记外两份必须一致 —— 否则说明它偷偷改了别的东西。
        #expect(online.modules == offline.modules)
        #expect(online.activeModuleTitle == offline.activeModuleTitle)
    }
}
