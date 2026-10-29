import SwiftUI

/// Setup embeds prototypes without another navigation wrapper.
/// Each switch is a device-local preference with no Gateway setting behind it.
struct ExperimentalSettingsContent: View {
    @PresentationState private var swiftApps = SwiftAppExperiment.shared

    var body: some View {
        TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                TronSettingsGroup("Swift Files", accent: .tronPrimary) {
                    TronToggleRow(
                        icon: "play.rectangle",
                        title: "Run Swift files",
                        detail: "Source previews stay read-only. Apps runner pairing is incomplete.",
                        isOn: $swiftApps.isEnabled
                    )
                    .accessibilityIdentifier("settings-experimental-swift-apps")
                }
                .tronSettingsVisualTheme(inheriting: .tronPrimary)
                .tronSettingsCaption("Saved on this iPhone. This preference does not currently enable a production runner or authorize app access.")
        }
    }
}
