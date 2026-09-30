import FluentWorkCore
import FluentWorkFeatureFlags

extension SettingsViewModel {
    /// State → the settings screen's plain model.
    ///
    /// Shows the **effective** value next to whether it came from an override, because those are the
    /// two things a device run needs to tell apart: a flag turned on by a local override behaves
    /// exactly like one that is on by default, and only one of them survives a reinstall.
    ///
    /// `appVersion` is a parameter rather than a `Bundle.main` read inside: the bundle is an app-layer
    /// fact (in a test process it is the test runner's bundle, so a projection that read it would
    /// print the wrong version in exactly the place you want to check the right one). The `"—"`
    /// fallback stays here because it is a **display** decision — "the version line is never blank".
    public static func make(
        from state: FeatureFlagsState,
        appVersion: String?
    ) -> SettingsViewModel {
        let flags = AppFeatureFlag.allCases.map { flag in
            SettingsViewModel.FlagRow(
                id: flag.rawValue,
                title: flag.rawValue,
                isEnabled: state.isEnabled(flag),
                isOverridden: state.localOverrides[flag] != nil
            )
        }
        return SettingsViewModel(
            flags: flags,
            appVersion: appVersion ?? "—",
            hasOverrides: !state.localOverrides.isEmpty
        )
    }
}
