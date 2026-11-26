import SwiftUI
import TronMobileCore

extension HomeTaskSheet.PendingRevocation.Target {
    var title: String {
        switch self {
        case .scope: "Revoke this scope?"
        case .grant: "Revoke this grant?"
        }
    }

    var message: String {
        switch self {
        case .scope: "Tasks in every trusted project stop being pre-approved. Each new task then asks on its exact card in Home's chat."
        case .grant: "This one-use grant stops covering its exact task binding."
        }
    }

    var command: HomeMutationCoordinator.Command {
        switch self {
        case .scope(let id): .revokeScope(id)
        case .grant(let id): .revokeGrant(id)
        }
    }
}

extension HomeTaskSheet {
    @ViewBuilder func permissionList(_ permissions: HomeTaskPermissionsDTO) -> some View {
        let scope = permissions.scopes.first(where: \.active)
        let grants = permissions.grants.filter { $0.state == .available }
        if scope != nil || permissions.needsReconfirmation || !grants.isEmpty {
            TronGlassCard {
                VStack(spacing: 0) {
                    if scope != nil || permissions.needsReconfirmation {
                        TronSettingsRow(icon: "lock.shield", title: "Home delegation", subtitle: "All trusted projects") {
                            TronStatusPill(text: permissions.needsReconfirmation ? "Reconfirm" : "Active",
                                           accent: permissions.needsReconfirmation ? .tronAmber : .tronEmerald)
                                .fixedSize()
                                .tronListMarker(.status)
                            if let scope { revokeButton(label: "Revoke scope \(scope.id)") { requestRevocation(.scope(scope.id)) } }
                        }
                        .accessibilityIdentifier("home-delegation")
                        .tronListMarkers("home-delegation")
                    }
                    if permissions.needsReconfirmation {
                        TronSettingsDivider()
                        Button { mutate(.reconfirmPermissions) } label: {
                            TronSettingsRow(icon: "checkmark.arrow.trianglehead.counterclockwise", title: "Reconfirm permissions",
                                            subtitle: "Restored standing scopes need your confirmation. One-use grants are never renewed.")
                        }
                        .buttonStyle(.plain)
                        .disabled(!canMutate)
                        .accessibilityIdentifier("home-permissions-reconfirm")
                    }
                    ForEach(Array(grants.enumerated()), id: \.element.id) { index, grant in
                        if index > 0 || scope != nil || permissions.needsReconfirmation { TronSettingsDivider() }
                        TronSettingsRow(icon: "key", title: grant.target,
                                        subtitle: "One-use grant · expires \(Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000).formatted())",
                                        titleIsIdentifier: true) {
                            revokeButton(label: "Revoke grant \(grant.id)") { requestRevocation(.grant(grant.id)) }
                        }
                        .accessibilityIdentifier("home-delegation-grant-\(grant.id)")
                        .tronListMarkers("home-delegation-grant-\(grant.id)")
                    }
                }
            }
        }
    }

    private func revokeButton(label: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            TronInlineActionLabel("Revoke", accent: .tronError, usesSemanticAccent: true)
        }
            .buttonStyle(.plain)
            .controlSize(.small)
            .tronSettingsVisualTheme(accent: .tronError)
            .disabled(!canMutate)
            .accessibilityLabel(label)
            .tronListMarker(.action)
    }
}
