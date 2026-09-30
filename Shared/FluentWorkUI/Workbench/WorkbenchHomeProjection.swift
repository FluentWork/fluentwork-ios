import FluentWorkCore

extension WorkbenchHomeViewModel {
    /// State → the workbench's plain model.
    ///
    /// Takes the four inputs it actually reads (`workspace` + the bootstrap status + the last error +
    /// the offline flag) rather than the whole root state. The old version reached into `store.state`
    /// for the last three, which made the function's name a promise it did not keep.
    ///
    /// `isOffline` names the **screen's** question ("should I say we are offline?"), not the state's
    /// fact (`network.isConnected`) — same shape as `DailyReadViewModel.make(from:isOffline:)`.
    public static func make(
        from workspace: WorkspaceState,
        bootstrapStatus: BootstrapStatus,
        lastErrorMessage: String?,
        isOffline: Bool
    ) -> WorkbenchHomeViewModel {
        let modules = workspace.availableModules.map { descriptor in
            Module(
                id: descriptor.moduleName,
                title: moduleTitle(
                    moduleName: descriptor.moduleName,
                    entryRoute: descriptor.entryRoute
                ),
                subtitle: moduleSubtitle(forEntryRoute: descriptor.entryRoute),
                systemImage: moduleIcon(forEntryRoute: descriptor.entryRoute),
                entryRoute: descriptor.entryRoute,
                kind: moduleKind(forEntryRoute: descriptor.entryRoute),
                // 「有没有入口」是**当前导航真的认不认这条路由**，不是「后端有没有这个能力」：
                // 一个注册了但路由解析不出来的模块，点进去是空的。所以它问 `AppRoute`。
                isAvailable: AppRoute(entryRoute: descriptor.entryRoute) != nil
            )
        }

        let phase: Phase
        switch bootstrapStatus {
        case .idle, .loading:
            phase = .loading
        case .ready:
            // 准备完成但一个模块都没有：那是「空」，不是「还在加载」—— 两者的屏幕文案不同，
            // 而把它们合成一个会让「加载完了但什么都没有」永远显示成转圈。
            phase = modules.isEmpty ? .empty : .ready
        case .failed:
            phase = .failed(message: lastErrorMessage)
        }

        return WorkbenchHomeViewModel(
            phase: phase,
            modules: modules,
            isOffline: isOffline,
            activeModuleTitle: activeModuleTitle(from: workspace.activeSurface),
            highlightedBadge: workspace.highlightedBadge,
            badgeFeedCount: workspace.badgeFeedCount
        )
    }

    /// The display name of a module.
    ///
    /// `default` returns `moduleName` as-is: the registry's name is the backend's own word for a
    /// module, and a module we have never heard of should say what it is called rather than fall back
    /// to a generic label that hides which one it is.
    private static func moduleTitle(moduleName: String, entryRoute: String) -> String {
        switch entryRoute {
        case "/speaking-room":
            return "说的房间"
        case "/review":
            return "回顾"
        case "/daily-read":
            return "每日一读"
        case "/sessions":
            return "练习历史"
        case "/drill":
            return "闪测"
        case "/topic-cards":
            return "话题建议"
        default:
            return moduleName
        }
    }

    private static func moduleSubtitle(forEntryRoute entryRoute: String) -> String {
        switch entryRoute {
        case "/speaking-room":
            return "进入实时口语练习，会话页使用全屏导航承载。"
        case "/review":
            return "查看评价、对照表达与炼句卡片，保持会话式全屏沉浸。"
        case "/daily-read":
            return "在工作台导航栈内进入阅读页，继续停留在当前 Tab。"
        case "/sessions":
            return "按时间回看每一场练习。列表按页加载，停留在当前 Tab。"
        case "/drill":
            // 文案说的是**按下去会发生什么**，因为这条特别容易猜错：它不开一页，它切 Tab。
            return "训练卡流、判定与申诉、结算都在底部「闪测」页内，点这里切到那个 Tab。"
        case "/topic-cards":
            return "读今天该聊的那几件，聊完回来打卡。停留在当前 Tab。"
        default:
            return "该模块尚未接入当前 MVP 导航。"
        }
    }

    private static func moduleIcon(forEntryRoute entryRoute: String) -> String {
        switch entryRoute {
        case "/speaking-room":
            return "mic.fill"
        case "/review":
            return "text.quote"
        case "/daily-read":
            return "book.fill"
        case "/sessions":
            return "clock.arrow.circlepath"
        case "/drill":
            // 与底部 Tab 2 的 `bolt` 同一个形状：同一个功能在两处出现时，
            // 图标不一致本身就是一条误导。
            return "bolt.fill"
        case "/topic-cards":
            return "bubble.left.and.bubble.right.fill"
        default:
            return "square.grid.2x2"
        }
    }

    private static func moduleKind(forEntryRoute entryRoute: String) -> Module.Kind {
        switch entryRoute {
        case "/speaking-room":
            return .speakingRoom
        case "/review":
            return .review
        case "/daily-read":
            return .dailyRead
        case "/sessions":
            return .sessionHistory
        case "/drill":
            return .drill
        case "/topic-cards":
            return .topicCards
        default:
            return .unsupported
        }
    }

    /// `nil` on the workbench itself — there is no "current module" to name when the list is what you
    /// are looking at.
    private static func activeModuleTitle(from surface: WorkspaceSurface) -> String? {
        switch surface {
        case .workbench:
            return nil
        case .speakingRoom:
            return "说的房间"
        case .review:
            return "回顾"
        }
    }
}
