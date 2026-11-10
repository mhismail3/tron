#if HOSTED_TEST
import SwiftUI
import UIKit

@MainActor
struct HostedThemeIconFixture: View {
    @State private var nativeState = "Not read"

    var body: some View {
        VStack(spacing: 16) {
            NavigationLink("Appearance") { AppearanceSettingsView() }
                .accessibilityIdentifier("theme-icon-open-appearance")
            Button("Read system icon") {
                let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
                let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
                let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
                nativeState = "theme=\(AppearanceSettings.shared.themeColor.rawValue);icon=\(UIApplication.shared.alternateIconName ?? "primary");primary=\(primary?["CFBundleIconName"] as? String ?? "missing");alternates=\(alternates.keys.sorted().joined(separator: ","))"
            }
            .accessibilityIdentifier("theme-icon-read-native")
            Text(nativeState).accessibilityIdentifier("theme-icon-native-state")
        }
        .font(TronFont.body())
        .foregroundStyle(Color.tronPrimary)
        .tronNavigationTitle("Theme icon boundary")
    }
}
#endif
