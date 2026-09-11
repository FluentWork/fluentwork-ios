import SwiftUI

/// What the settings screen shows. Plain data on purpose: this module has never
/// depended on the feature-flag types, and the host maps state into this — the
/// same split `ReviewViewModel` uses.
public struct SettingsViewModel: Equatable, Sendable {
    public struct FlagRow: Identifiable, Equatable, Sendable {
        /// The flag's raw value. A `String` rather than the enum so this module
        /// stays free of `FluentWorkFeatureFlags`; the host maps it back, and
        /// the round trip is lossless because the enum is `String`-backed.
        public let id: String
        public let title: String
        public let isEnabled: Bool
        /// Whether the current value comes from a local override rather than
        /// the build's defaults. Worth showing: an override is what the device
        /// test turns on and forgets to turn off, and the two look identical
        /// without it.
        public let isOverridden: Bool

        public init(id: String, title: String, isEnabled: Bool, isOverridden: Bool) {
            self.id = id
            self.title = title
            self.isEnabled = isEnabled
            self.isOverridden = isOverridden
        }
    }

    public var flags: [FlagRow]
    public var appVersion: String
    public var hasOverrides: Bool

    public init(flags: [FlagRow], appVersion: String, hasOverrides: Bool) {
        self.flags = flags
        self.appVersion = appVersion
        self.hasOverrides = hasOverrides
    }

    public static let empty = SettingsViewModel(flags: [], appVersion: "", hasOverrides: false)
}

/// The settings screen.
///
/// A real product surface, not a debug menu — the PRD's information
/// architecture already has one (G2, AI speech rate, lands here). The feature
/// flags live in a section that only exists in **DEBUG builds**, so what ships
/// is a settings page with nothing experimental in it.
///
/// Reachable without a flag gating it, deliberately: every other surface is a
/// `FeaturePluginDescriptor` filtered by its own flag, and a settings page
/// behind a flag could only be opened by someone who had already turned that
/// flag on — which is the one thing it exists to let you do.
public struct SettingsRootView: View {
    private let model: SettingsViewModel
    private let onToggleFlag: (String, Bool) -> Void
    private let onClearOverrides: () -> Void

    public init(
        model: SettingsViewModel,
        onToggleFlag: @escaping (String, Bool) -> Void,
        onClearOverrides: @escaping () -> Void
    ) {
        self.model = model
        self.onToggleFlag = onToggleFlag
        self.onClearOverrides = onClearOverrides
    }

    public var body: some View {
        List {
            aboutSection
            #if DEBUG
                developerSection
            #endif
        }
        .navigationTitle("设置")
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: model.appVersion)
        }
    }

    #if DEBUG
        private var developerSection: some View {
            Section {
                ForEach(model.flags) { row in
                    Toggle(isOn: binding(for: row)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            if row.isOverridden {
                                Text("已被本地覆盖")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // The escape hatch a device run needs. An override set on a
                // phone outlives the test that set it, and there is no other
                // way back to the build's defaults short of reinstalling.
                Button("清除全部本地覆盖", role: .destructive) {
                    onClearOverrides()
                }
                .disabled(!model.hasOverrides)
            } header: {
                Text("开发者")
            } footer: {
                Text("本地覆盖只影响这台设备，不会写进版本库。真机验证需要开关的实验性能力时用它。")
            }
        }

        private func binding(for row: SettingsViewModel.FlagRow) -> Binding<Bool> {
            Binding(
                get: { row.isEnabled },
                set: { onToggleFlag(row.id, $0) }
            )
        }
    #endif
}
