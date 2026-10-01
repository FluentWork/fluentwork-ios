import SwiftUI

extension View {
    /// 稿子 §03 的**「全屏页（从入口推入）」**。
    ///
    /// 稿子的信息架构把页面分成两类：一类是 tab（工作台 / 闪测 / 语料库），
    /// 另一类是**全屏页** —— 说的房间 · 回顾页 · 每日一读 · 话题建议 · 设置。
    /// 全屏页有两个特征同时成立：
    ///
    /// 1. **从入口推入**（不是切 tab）⇒ 落在那条入口所在栈的 `NavigationStack` 上；
    /// 2. **盖住底部**（页面整屏，底部不该还留着 tab bar）。
    ///
    /// 第 2 条不会自动成立：`NavigationStack` 的推入发生在 **tab 容器内部**，
    /// 所以推入的页默认**带着 tab bar**（这是 SwiftUI 的行为，不是谁的错）。
    /// 这个修饰符就是补上那一条 —— 一行，但少了它就只是「半个全屏页」。
    ///
    /// 用法是**加在目的地视图上**（而不是发起推入的地方）：全屏与否是**那一页自己的属性**，
    /// 谁把它推出来的都该一样。五个全屏页共用这一个修饰符，将来不会各自漂。
    @ViewBuilder
    public func fullScreenPage() -> some View {
        // `toolbar(_:for: .tabBar)` 只在 iOS/tvOS 有。这个包同时构建 macOS
        // （`swift test` 就跑在 macOS 上），所以这里必须分平台 —— 而 macOS 上
        // 本来也没有 tab bar 可盖，返回自身就是对的。
        #if os(iOS) || os(tvOS)
            return self
                .toolbar(.hidden, for: .tabBar)
                // 顶栏用 **inline**：稿子的 `.app-bar` 是 `min-height: 44px` ＋ `h1 { 17px }`
                // ——一根紧凑的标题条，不是 iOS 的大标题（大标题字号差不多是它的两倍，
                // 一进来就把内容挤到屏幕下半截）。
                .navigationBarTitleDisplayMode(.inline)
        #else
            return self
        #endif
    }
}
