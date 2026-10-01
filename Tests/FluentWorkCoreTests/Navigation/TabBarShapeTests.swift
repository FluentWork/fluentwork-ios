import FluentWorkCore
import FluentWorkPluginSupport
import Testing

/// 底部导航的形状：**三个 tab**，设置是工作台上推入的一页。
///
/// 这处分歧在仓里挂了很久 —— 稿子 §03 写「底部导航固定 3 项」，而实现里曾有第 4 个
/// `settings`，`AppTab` 的注释与 meta 的「底部 Tab 数」一行都记着它「已知且尚未拍板」。
/// 2026-10-01 按稿子拍板。这一组判据把决定**钉住**：再有人把设置放回 tab bar，
/// 会先红在这里，而不是悄悄漂回四 tab。
@Suite("底部导航 · 三个 tab")
struct TabBarShapeTests {

    /// 三个，顺序也钉住（顺序变了是可见变化，不该是偶然）。
    @Test func 底部导航是三项且顺序稳定() {
        #expect(AppTab.allCases == [.workbench, .flashTest, .corpus])
    }

    /// 设置**不在** tab 里。
    @Test func 设置不是一个tab() {
        #expect(AppTab.allCases.contains { $0.rawValue == "settings" } == false)
    }

    /// 设置是**工作台那条栈上推入的一页**（稿子 屏 12 的顶栏：「← 返回工作台 ＋ 设置」）。
    @Test func 设置从工作台推入() {
        #expect(AppRoute.settings.defaultWorkbenchNavigationAction == .workbench(.push(.settings)))
        #expect(AppRoute.settings.entryRoute == "/settings")
        #expect(AppRoute(entryRoute: "/settings") == .settings)
    }

    /// 设置这条路由**不经过开关门禁**。
    ///
    /// 它是唯一能把实验性开关打开的地方，而插件是按自己的开关过滤的 ——
    /// 一个被开关挡在门外的设置页，只有已经打开过那个开关的人才进得去。
    /// 从前这条理由靠「设置是一个 tab」成立，现在靠「它是一条裸路由」成立。
    @Test func 设置不受开关门禁() {
        let gatedRoutes = FeaturePluginCatalog.firstWave.map(\.entryRoute)
        #expect(
            gatedRoutes.contains("/settings") == false,
            "有插件认领了 /settings —— 那它就会被那个插件的开关挡住，而它正是开开关的地方"
        )
    }
}
