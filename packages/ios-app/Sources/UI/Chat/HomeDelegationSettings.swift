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
    func permissionList(_ permissions: HomeTaskPermissionsDTO) -> some View {
        let scope = permissions.scopes.first(where: \.active)
        let pill: (String, Color) = scope == nil ? ("Not authorized", .tronSlate)
            : permissions.needsReconfirmation ? ("Reconfirm", .tronAmber) : ("Active", .tronEmerald)
        return TronGlassCard {
            VStack(spacing: 0) {
                TronSettingsRow(icon: "lock.shield", title: "Home delegation: All trusted projects") {
                    TronStatusPill(text: pill.0, accent: pill.1).fixedSize()
                    if let scope { revokeButton(label: "Revoke scope \(scope.id)") { requestRevocation(.scope(scope.id)) } }
                }
                .accessibilityIdentifier("settings-home-delegation")
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
                ForEach(permissions.grants) { grant in
                    TronSettingsDivider()
                    TronSettingsRow(icon: "key", title: grant.target,
                                    subtitle: "One-use grant · expires \(Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000).formatted())",
                                    titleIsIdentifier: true) {
                        let grantPill = Self.grantPill(grant.state)
                        TronStatusPill(text: grantPill.0, accent: grantPill.1).fixedSize()
                        if grant.state == .available {
                            revokeButton(label: "Revoke grant \(grant.id)") { requestRevocation(.grant(grant.id)) }
                        }
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
            .padding(.leading, TronSpacing.md)
            .disabled(!canMutate)
            .accessibilityLabel(label)
    }

    static func grantPill(_ state: HomeTaskPermissionsDTO.Grant.State) -> (String, Color) {
        switch state {
        case .available: ("Available", .tronEmerald)
        case .consumed: ("Used", .tronSlate)
        case .revoked: ("Revoked", .tronSlate)
        }
    }
}
