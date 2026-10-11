import SwiftUI
import TronMobileCore

/// Task permissions: standing scopes, one-use grants and pending requests, each a
/// group of standard rows. Revoking is destructive and asks first.
extension HomeTaskSheet.HomeRevocation {
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
            Text("After a restore, reconfirm active standing scopes. This never renews one-use grants or revoked scopes.")
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
            actionRow(title: "Reconfirm permissions", icon: "checkmark.arrow.trianglehead.counterclockwise",
                      id: "home-permissions-reconfirm", enabled: canMutate) { mutate(.reconfirmPermissions) }
            sectionCard("Standing scopes") {
                if permissions.scopes.isEmpty {
                    mutedLine("No standing scopes")
                } else {
                    rowGroup(permissions.scopes) { scope in
                        permissionRow(title: "All trusted projects", detail: scope.id,
                                      pill: scope.active ? ("Active", Color.tronEmerald) : ("Revoked", Color.tronSlate)) {
                            if scope.active { revokeButton(label: "Revoke scope \(scope.id)") { revoking = .scope(scope.id) } }
                        }
                    }
                }
            }
            sectionCard("One-use grants") {
                if permissions.grants.isEmpty {
                    mutedLine("No one-use grants")
                } else {
                    rowGroup(permissions.grants) { grant in
                        permissionRow(title: grant.target, detail: "Expires \(Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000).formatted())",
                                      pill: Self.grantPill(grant.state)) {
                            if grant.state == .available { revokeButton(label: "Revoke grant \(grant.id)") { revoking = .grant(grant.id) } }
                        }
                    }
                }
            }
            sectionCard("Pending requests") {
                if permissions.pendingRequests.isEmpty {
                    mutedLine("No pending requests")
                } else {
                    rowGroup(permissions.pendingRequests) { request in
                        Button { child = .grant(request) } label: {
                            permissionRow(title: request.request.target, detail: "Awaiting your decision", pill: ("Pending", Color.tronWarning)) {
                                Image(systemName: "chevron.right")
                                    .font(TronTypography.caption)
                                    .foregroundStyle(Color.tronSessionTeal)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Review request \(request.id)")
                        .accessibilityIdentifier("home-permission-request-\(request.id)")
                    }
                }
            }
            if permissions.scopes.isEmpty && permissions.grants.isEmpty && permissions.pendingRequests.isEmpty {
                TronPlaceholderState(title: "No task permissions", detail: "No standing scopes, grants or pending requests are recorded.", icon: "lock")
            }
            actionRow(title: "Reload permissions", icon: "arrow.clockwise", id: "home-permissions-reload") { reload() }
        }
    }

    func grantDecision(_ request: HomeTaskPermissionsDTO.Request, permissions: HomeTaskPermissionsDTO) -> some View {
        let pending = permissions.pendingRequests.first { $0 == request }
        return VStack(alignment: .leading, spacing: 14) {
            sectionCard("Request") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.request.target).font(TronTypography.bodySM).textSelection(.enabled)
                    Text("Scope: \(request.request.authorizationScope)").font(TronTypography.secondaryDescription)
                    Text(request.request.intentDigest).font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextMuted).textSelection(.enabled)
                }
            }
            if pending != nil {
                DatePicker("Expiry", selection: $expiry, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .font(TronTypography.bodySM).accessibilityIdentifier("home-grant-expiry")
                Text("Choose a future expiry. Approval creates one grant for this exact binding; it does not replay the refused task. Denial records a decision without a grant.")
                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                actionRow(title: "Approve request", icon: "checkmark.circle", id: "home-grant-approve",
                          enabled: canMutate && expiry > .now) { decide(request.id, approved: true) }
                actionRow(title: "Deny request", icon: "xmark.circle", destructive: true, id: "home-grant-deny",
                          enabled: canMutate && expiry > .now) { decide(request.id, approved: false) }
            } else {
                mutedLine(permissions.decisions.first { $0.requestId == request.id }?.approved == true ? "Approved" : "Denied or no longer pending")
            }
        }
    }

    func decide(_ request: String, approved: Bool) {
        let milliseconds = expiry.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > Date.now.timeIntervalSince1970 * 1000 else { return }
        mutate(.decideGrant(requestID: request, approved: approved, expiresAt: Int(milliseconds)))
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
        }
        .buttonStyle(.borderless)
        .disabled(!canMutate)
        .accessibilityLabel(label)
    }

    private func mutedLine(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(Color.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
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
