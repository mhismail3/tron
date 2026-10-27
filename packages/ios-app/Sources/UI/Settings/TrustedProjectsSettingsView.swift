import SwiftUI
import TronMobileCore

/// Global Settings' single entrypoint. The former embedded toggle/Add write
/// route is replaced by native lifecycle pages and the canonical approval sheet.
struct TrustedProjectsSettingsView: View {
    static let key = "permissions.projectTrust"
    static let policyKey = "permissions.defaultProjectTrust"
    static let keys: Set<String> = [key, policyKey]

    private enum Entry: String, Identifiable {
        case projects
        var id: String { rawValue }
    }

    var body: some View {
        TronListGroup([Entry.projects], identifier: "trusted-projects-entry") { _ in
            TronProgressiveSheetLink(accessibilityLabel: "Trusted Projects", detents: .fixed([.large])) {
                ProjectLifecycleView(route: .list)
            } label: {
                TronListRow(TronListRowContent(leading: .icon("checkmark.shield", .tronPrimary), title: "Trusted Projects"))
            }
        }
    }
}
