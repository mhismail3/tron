import SwiftUI

struct ExperimentalSettingsContent: View {
    @PresentationState private var swiftApps = SwiftAppExperiment.shared

    var body: some View {
        TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                TronSettingsGroup("Swift Files", accent: .tronPrimary) {
                    TronToggleRow(
                        icon: "play.rectangle",
                        title: "Run Swift files",
                        detail: "Adds a Run button to .swift previews. Sandboxed; simulator-tested only.",
                        isOn: $swiftApps.isEnabled
                    )
                    .accessibilityIdentifier("settings-experimental-swift-apps")
                }
                .tronSettingsVisualTheme(inheriting: .tronPrimary)
                .tronSettingsCaption("Run opens a single-file SwiftUI app shown in chat as a native app, with no file, network or system access. Applies only to this iPhone.")
        }
    }
}
