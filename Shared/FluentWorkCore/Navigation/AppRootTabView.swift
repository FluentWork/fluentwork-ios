import SwiftUI
import TGNavigationStack

/// Host-facing tab shell: 3 tabs each backed by `TGNavigationStack` + Store dispatch.
@MainActor
public struct AppRootTabView<WorkbenchRoot: View, FlashRoot: View, CorpusRoot: View>: View {
    private let navigation: AppNavigationState
    private let dispatch: (AppAction) -> Void
    private let workbenchRoot: () -> WorkbenchRoot
    private let flashRoot: () -> FlashRoot
    private let corpusRoot: () -> CorpusRoot
    private let destination: (AppRoute) -> AnyView

    public init(
        navigation: AppNavigationState,
        dispatch: @escaping (AppAction) -> Void,
        @ViewBuilder workbenchRoot: @escaping () -> WorkbenchRoot,
        @ViewBuilder flashRoot: @escaping () -> FlashRoot,
        @ViewBuilder corpusRoot: @escaping () -> CorpusRoot,
        destination: @escaping (AppRoute) -> AnyView
    ) {
        self.navigation = navigation
        self.dispatch = dispatch
        self.workbenchRoot = workbenchRoot
        self.flashRoot = flashRoot
        self.corpusRoot = corpusRoot
        self.destination = destination
    }

    public var body: some View {
        TabView(selection: selectedTabBinding) {
            tabStack(
                for: .workbench,
                title: "工作台",
                systemImage: "square.grid.2x2",
                root: workbenchRoot
            )
            tabStack(
                for: .flashTest,
                title: "闪测",
                systemImage: "bolt",
                root: flashRoot
            )
            tabStack(
                for: .corpus,
                title: "语料库",
                systemImage: "books.vertical",
                root: corpusRoot
            )
        }
    }

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { navigation.selectedTab },
            set: { dispatch(.navigation(.selectTab($0))) }
        )
    }

    @ViewBuilder
    private func tabStack(
        for tab: AppTab,
        title: String,
        systemImage: String,
        @ViewBuilder root: @escaping () -> some View
    ) -> some View {
        TGNavigationStack(
            state: navigation.stack(for: tab),
            dispatch: { action in
                switch tab {
                case .workbench:
                    dispatch(.navigation(.workbench(action)))
                case .flashTest:
                    dispatch(.navigation(.flashTest(action)))
                case .corpus:
                    dispatch(.navigation(.corpus(action)))
                }
            }
        ) {
            root()
                .navigationTitle(title)
        } destination: { route in
            destination(route)
        }
        .tabItem {
            Label(title, systemImage: systemImage)
        }
        .tag(tab)
    }
}
