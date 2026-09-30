import FluentWorkCore
import FluentWorkFeatureFlags
import Testing

@testable import FluentWorkUI

/// `SettingsViewModel.make(from:appVersion:)` —— 设置页的投影。
///
/// 这一份此前是 `HostRootView` 的 `private func`，住在 **app target**（没有测试 target）。
/// 它同时读 `Bundle.main`，而那在测试进程里是**测试 runner 的** bundle ——
/// 所以「版本号显示得对不对」恰恰是搬迁之前无法检查的一件事。
@Suite("设置页的投影")
struct SettingsProjectionTests {

    /// 未覆盖任何开关的状态：快照里开着 first-wave 那几档。
    private func state(
        enabled: Set<AppFeatureFlag> = [],
        overrides: [AppFeatureFlag: Bool] = [:]
    ) -> FeatureFlagsState {
        FeatureFlagsState(
            snapshot: FeatureFlagSnapshot(enabledFlags: enabled),
            localOverrides: overrides
        )
    }

    /// **每一档开关都在列表里，顺序跟 `allCases` 一致。**
    ///
    /// 设置页是唯一能把开关打开的地方（`AppTab.settings` 刻意不受 flag 门禁），所以漏掉一档
    /// 等于那一档在真机上根本没法开。顺序也钉住：列表顺序变了是可见变化，不该是偶然。
    @Test func 每一档开关都在列表里且顺序稳定() {
        let model = SettingsViewModel.make(from: state(), appVersion: nil)

        #expect(
            model.flags.map(\.id) == AppFeatureFlag.allCases.map(\.rawValue),
            "开关列表与 allCases 不一致（漏了或换序了）"
        )
        #expect(model.flags.map(\.title) == model.flags.map(\.id), "标题与 id 应该同源")
    }

    /// `isEnabled` 报的是**生效值**，而 `isOverridden` 说的是它从哪来。
    ///
    /// 这两件事在设置页上并排显示，而设备验证时唯一能区分的正是它们：被本地覆盖打开的开关与
    /// 默认就开的行为完全一样，只有其中一个能活过一次重装。
    @Test func 生效值与来源是两件事() {
        // ① 快照开着、没有覆盖 ⇒ 生效、未覆盖
        let snapshotOn = SettingsViewModel.make(
            from: state(enabled: [.voiceVadAuto]),
            appVersion: nil
        )
        #expect(snapshotOn.flags.first { $0.id == AppFeatureFlag.voiceVadAuto.rawValue }?.isEnabled == true)
        #expect(snapshotOn.flags.first { $0.id == AppFeatureFlag.voiceVadAuto.rawValue }?.isOverridden == false)

        // ② 快照没开、本地覆盖打开 ⇒ 生效、且标记为覆盖
        let overrideOn = SettingsViewModel.make(
            from: state(overrides: [.voiceVadAuto: true]),
            appVersion: nil
        )
        let row = overrideOn.flags.first { $0.id == AppFeatureFlag.voiceVadAuto.rawValue }
        #expect(row?.isEnabled == true, "覆盖没有拿出来当生效值")
        #expect(row?.isOverridden == true, "它的来源没有被标出来")

        // ③ 快照开着、本地覆盖**关掉** ⇒ 不生效、且仍是覆盖
        let overrideOff = SettingsViewModel.make(
            from: state(enabled: [.voiceVadAuto], overrides: [.voiceVadAuto: false]),
            appVersion: nil
        )
        let off = overrideOff.flags.first { $0.id == AppFeatureFlag.voiceVadAuto.rawValue }
        #expect(off?.isEnabled == false, "覆盖关掉没有赢过快照")
        #expect(off?.isOverridden == true, "它仍然是一次本地覆盖")
    }

    /// 「有没有覆盖」是**整块**的：它决定「清除全部覆盖」那个控件显不显示。
    ///
    /// 关掉一档也算一次覆盖 —— 只看「有没有被打开过」的实现会漏掉这种状态，于是那一档再也清不掉。
    @Test func 有没有覆盖是整块的事() {
        #expect(SettingsViewModel.make(from: state(), appVersion: nil).hasOverrides == false)
        #expect(
            SettingsViewModel.make(
                from: state(overrides: [.corpus: false]),
                appVersion: nil
            ).hasOverrides,
            "只覆盖「关掉」一档时，清除入口没有出现 —— 那一档就再也清不掉了"
        )
    }

    /// 版本号：给了就用，没给就落到「—」，**永远不留空白**。
    @Test func 版本号没给也不留空白() {
        #expect(
            SettingsViewModel.make(from: state(), appVersion: "1.2.3").appVersion == "1.2.3"
        )
        #expect(
            SettingsViewModel.make(from: state(), appVersion: nil).appVersion == "—",
            "读不到版本号时那一行会空着 —— 而它正是排查时最要紧的一行"
        )
    }
}
