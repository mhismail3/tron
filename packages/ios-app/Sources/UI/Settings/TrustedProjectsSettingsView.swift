import SwiftUI
import TronMobileCore

struct TrustedProjectsSettingsView: View {
    static let key = "permissions.projectTrust"
    static let policyKey = "permissions.defaultProjectTrust"
    static let keys: Set<String> = [key, policyKey]

    var body: some View {
        TronSettingsGroup("Projects") {
            TronProgressiveSheetLink(accessibilityLabel: "Trusted Projects") {
                ProjectLifecycleView(route: .list)
            } label: {
                TronSettingsRow(icon: "checkmark.shield", title: "Trusted Projects")
            }
        }
    }
}
