import SwiftUI
import TronMobileCore

/// Task permission controls stay with Home's receipted mutation owner even
/// though their presentation is embedded in the generic settings surface.
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
        VStack(alignment: .leading, spacing: TronSpacing.section) {
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
                }
            }
            if !permissions.grants.isEmpty {
                TronSettingsGroup("One-use grants") {
                    VStack(spacing: 0) {
                        ForEach(Array(permissions.grants.enumerated()), id: \.element.id) { index, grant in
                            if index > 0 { TronSettingsDivider() }
                            TronSettingsRow(icon: "key", title: grant.target,
                                            subtitle: "Expires \(Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000).formatted())",
                                            titleIsIdentifier: true) {
                                let pill = Self.grantPill(grant.state)
                                TronStatusPill(text: pill.0, accent: pill.1).fixedSize()
                                if grant.state == .available {
                                    revokeButton(label: "Revoke grant \(grant.id)") { requestRevocation(.grant(grant.id)) }
                                }
                            }
                        }
                    }
                }
            }
            if !permissions.pendingRequests.isEmpty {
                TronSettingsGroup("Pending requests", detail: "Approval covers this exact task only; it does not replay it.") {
                    VStack(spacing: 0) {
                        ForEach(Array(permissions.pendingRequests.enumerated()), id: \.element.id) { index, request in
                            if index > 0 { TronSettingsDivider() }
                            HomeGrantRequestRow(request: request, enabled: canMutate) { approved, expiresAt in
                                mutate(.decideGrant(requestID: request.id, approved: approved, expiresAt: expiresAt))
                            }
                        }
                    }
                }
            }
        }
    }

    private func revokeButton(label: String, action: @escaping () -> Void) -> some View {
        Button("Revoke", role: .destructive, action: action)
            .font(TronTypography.buttonSM)
            .foregroundStyle(Color.tronError)
            .buttonStyle(.borderless)
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

/// A pending request owns only its expiry draft. Every piece of its layout is
/// a standard settings row; split date/time so native controls fit that row.
private struct HomeGrantRequestRow: View {
    let request: HomeTaskPermissionsDTO.Request
    let enabled: Bool
    let onDecide: (Bool, Int) -> Void
    @PresentationState private var expiry = Date.now.addingTimeInterval(3600)

    var body: some View {
        VStack(spacing: 0) {
            TronSettingsRow(icon: "lock", title: request.request.target,
                            subtitle: "One task · \(request.request.authorizationScope)", titleIsIdentifier: true) {
                TronStatusPill(text: "Pending", accent: .tronWarning)
            }
            TronSettingsDivider()
            TronSettingsRow(icon: "calendar", title: "Expiry date") {
                DatePicker("Expiry date", selection: $expiry, in: Date.now..., displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityIdentifier("home-grant-expiry-date-\(request.id)")
            }
            TronSettingsDivider()
            TronSettingsRow(icon: "clock", title: "Expiry time") {
                DatePicker("Expiry time", selection: $expiry, in: Date.now..., displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityIdentifier("home-grant-expiry-time-\(request.id)")
            }
            TronSettingsDivider()
            TronSettingsRow(icon: "checkmark.shield", title: "Decision") {
                Button("Approve") { decide(true) }
                    .buttonStyle(TronActionButtonStyle(expands: false))
                    .accessibilityLabel("Approve request")
                    .accessibilityIdentifier("home-grant-approve-\(request.id)")
                Button("Deny", role: .destructive) { decide(false) }
                    .buttonStyle(TronActionButtonStyle(role: .destructive, expands: false))
                    .accessibilityLabel("Deny request")
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
