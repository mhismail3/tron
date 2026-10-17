import SwiftUI

/// Settings › Tools & Diagnostics › Experimental: prototypes this iPhone can opt into.
/// Each switch is a device-local preference with no Gateway setting behind it.
struct ExperimentalSettingsView: View {
    @PresentationState private var swiftApps = SwiftAppExperiment.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Swift Files", accent: .tronEmerald) {
                    TronToggleRow(
                        icon: "play.rectangle",
                        title: "Run Swift files",
                        detail: "Adds a Run button to .swift previews. Sandboxed; simulator-tested only.",
                        isOn: $swiftApps.isEnabled
                    )
                    .accessibilityIdentifier("settings-experimental-swift-apps")
                }
                .tronSettingsVisualTheme(inheriting: .tronEmerald)
                .tronSettingsCaption("Run opens a single-file SwiftUI app shown in chat as a native app, with no file, network or system access. Applies only to this iPhone.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Experimental")
    }
}
