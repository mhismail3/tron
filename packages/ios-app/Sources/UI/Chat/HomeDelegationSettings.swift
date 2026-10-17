import SwiftUI
import TronMobileCore

/// Task permissions: standing scopes, one-use grants and pending requests, each a
/// group of standard rows. Revoking is destructive and asks first.
extension HomeTaskSheet.PendingRevocation.Target {
    var title: String {
        switch self {
        case .scope: "Revoke this scope?"
        case .grant: "Revoke this grant?"
        }
    }

    var message: String {
        switch self {
        case .scope: "Tasks in every trusted project stop being pre-approved. Pending requests still ask first."
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
        VStack(alignment: .leading, spacing: 14) {
            TronSettingsGroup("Permissions") {
                VStack(spacing: 0) {
                    if permissions.scopes.isEmpty {
                        TronSettingsRow(icon: "lock.shield", title: "Delegation: All trusted projects") {
                            TronStatusPill(text: "Not authorized", accent: .tronSlate)
                        }
                    } else {
                        ForEach(Array(permissions.scopes.enumerated()), id: \.element.id) { index, scope in
                            if index > 0 { TronSettingsDivider() }
                            TronSettingsRow(icon: "lock.shield", title: "Delegation: All trusted projects") {
                                TronStatusPill(text: scope.active ? (permissions.needsReconfirmation ? "Reconfirm" : "Active") : "Revoked",
                                               accent: scope.active ? (permissions.needsReconfirmation ? .tronWarning : .tronEmerald) : .tronSlate)
                                    .fixedSize()
                                if scope.active { revokeButton(label: "Revoke scope \(scope.id)") { requestRevocation(.scope(scope.id)) } }
                            }
                        }
                    }
                }
            }
            if permissions.needsReconfirmation {
                actionRow(title: "Reconfirm permissions", subtitle: "Restored standing scopes need your confirmation. One-use grants are never renewed.",
                          icon: "checkmark.arrow.trianglehead.counterclockwise",
                          id: "home-permissions-reconfirm", enabled: canMutate) { mutate(.reconfirmPermissions) }
            }
            if !permissions.grants.isEmpty {
                sectionCard("One-use grants") {
                    rowGroup(permissions.grants) { grant in
                        permissionRow(title: grant.target, detail: "Expires \(Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000).formatted())",
                                      pill: Self.grantPill(grant.state)) {
                            if grant.state == .available { revokeButton(label: "Revoke grant \(grant.id)") { requestRevocation(.grant(grant.id)) } }
                        }
                    }
                }
            }
            if !permissions.pendingRequests.isEmpty {
                sectionCard("Pending requests") {
                    rowGroup(permissions.pendingRequests) { request in
                        HomeGrantRequestRow(request: request, enabled: canMutate) { approved, expiresAt in
                            mutate(.decideGrant(requestID: request.id, approved: approved, expiresAt: expiresAt))
                        }
                    }
                }
            }
        }
    }

    private func permissionRow<Trailing: View>(title: String, detail: String, pill: (String, Color),
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(2)
                Text(detail)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TronStatusPill(text: pill.0, accent: pill.1)
            trailing()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func revokeButton(label: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text("Revoke")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronError)
        }
        .buttonStyle(.borderless)
        .disabled(!canMutate)
        .accessibilityLabel(label)
    }

    /// Rows separated by dividers inside one card's content.
    private func rowGroup<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                row(item)
            }
        }
    }

    static func grantPill(_ state: HomeTaskPermissionsDTO.Grant.State) -> (String, Color) {
        switch state {
        case .available: ("Available", .tronEmerald)
        case .consumed: ("Used", .tronSlate)
        case .revoked: ("Revoked", .tronSlate)
        }
    }
}

/// A pending request alone owns its expiry draft. Decisions stay with Home's
/// receipted mutation coordinator; opening or editing the date sends nothing.
private struct HomeGrantRequestRow: View {
    let request: HomeTaskPermissionsDTO.Request
    let enabled: Bool
    let onDecide: (Bool, Int) -> Void
    @PresentationState private var expiry = Date.now.addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TronSettingsRow(icon: "lock", title: request.request.target,
                            subtitle: "One task · \(request.request.authorizationScope)") {
                TronStatusPill(text: "Pending", accent: .tronWarning)
            }
            DatePicker("Expiry", selection: $expiry, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .font(TronTypography.bodySM)
                .accessibilityIdentifier("home-grant-expiry-\(request.id)")
            TronSettingsCaption("Approval covers this exact task only; it does not replay it.")
            HStack {
                Button("Approve request", systemImage: "checkmark.circle") { decide(true) }
                    .buttonStyle(TronActionButtonStyle(accent: .tronEmerald))
                    .accessibilityIdentifier("home-grant-approve-\(request.id)")
                Button("Deny request", systemImage: "xmark.circle") { decide(false) }
                    .buttonStyle(TronActionButtonStyle(role: .destructive))
                    .accessibilityIdentifier("home-grant-deny-\(request.id)")
            }
            .disabled(!enabled || expiry <= .now)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-permission-request-\(request.id)")
        .contextMenu { Text(request.request.intentDigest) }
    }

    private func decide(_ approved: Bool) {
        let milliseconds = expiry.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > Date.now.timeIntervalSince1970 * 1000,
              milliseconds < Double(Int.max) else { return }
        onDecide(approved, Int(milliseconds))
    }
}
