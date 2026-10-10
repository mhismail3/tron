import SwiftUI
import TronMobileCore

struct HomePinnedRow: View {
    let status: HomeStatusDTO?
    /// A Home command is running for this profile. It and `hasUnresolvedCommand`
    /// are exclusive: the mutation coordinator holds one state per profile.
    let isChanging: Bool
    var hasUnresolvedCommand = false
    /// The mounted read reached a Gateway whose status could not be read or
    /// admitted; the row must not keep saying it is loading.
    var isStatusUnavailable = false

    private var action: HomePinnedRowAction {
        HomePinnedRowPolicy.action(for: status, hasUnresolvedCommand: hasUnresolvedCommand)
    }
    private var detail: String {
        if isChanging { return "Updating Home…" }
        if hasUnresolvedCommand { return "Home change pending · Tap to check" }
        guard let status else { return isStatusUnavailable ? "Home status unavailable" : "Loading Home status…" }
        switch status.phase {
        case .undesignated: return "Set up your Home session"
        case .disabled: return "Disabled · Tap to re-enable"
        case .missingSession: return "Session missing · Tap to restore"
        case .blocked:
            let explanation = status.memory.blocked ?? status.memory.reason
                ?? status.recovery.reason ?? status.readiness.gaps.first
            return explanation.map { "Blocked · \($0)" } ?? "Blocked · Open chat to inspect"
        case .paused: return "Memory paused · Open chat to resume"
        case .rolloverPending: return "Recovery needed · Chapter transition pending"
        case .active: return "Working"
        case .ready: return "Ready"
        case .unavailable: return status.reason ?? "Home is unavailable"
        }
    }

    private var trailing: String {
        if isChanging { return "Updating" }
        if hasUnresolvedCommand { return "Check status" }
        switch action {
        case .checkReceipt: return "Check status"
        case .designate: return "Set up"
        case .open:
            switch status?.phase {
            case .active: return "Working"
            case .paused: return "Paused"
            case .rolloverPending: return "Recovery needed"
            case .blocked: return "Blocked"
            default: return "Ready"
            }
        case .unavailable: return status == nil && !isStatusUnavailable ? "Loading" : "Unavailable"
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .padding(.horizontal, SessionDashboardLayout.rowContentHorizontalPadding)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .tronGlassSurface(accent: .tronEmerald, cornerRadius: 12, tintOpacity: 0.14, interactive: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Home, \(detail), \(trailing)")
        .accessibilityIdentifier("home-pinned-row-content")
    }

    private var horizontalLayout: some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            icon
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 10)
            trailingLabel
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: SessionDashboardLayout.iconTextSpacing) {
                icon
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer(minLength: 0)
                trailingLabel
            }
        }
    }

    private var icon: some View {
        Image(systemName: "house.fill")
            .font(TronTypography.sans(size: SessionDashboardLayout.headerIconSize, weight: .semibold))
            .foregroundStyle(Color.tronEmerald)
            .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)
            .accessibilityHidden(true)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Home")
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(Color.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trailingLabel: some View {
        HStack(spacing: 5) {
            if isChanging {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(trailing)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(action == .unavailable ? Color.tronTextMuted : Color.tronEmerald)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
