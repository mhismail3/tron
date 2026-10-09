import SwiftUI
import TronMobileCore

// Home does not appear in the ordinary session catalog. Its explicit states
// keep unavailable and stale session identities from becoming route targets.
enum HomePinnedRowAction: Equatable {
    case checkReceipt
    case designate
    case open(sessionID: String)
    case unavailable
}

enum HomePinnedRowPolicy {
    static func action(
        for status: HomeStatusDTO?,
        hasUnresolvedCommand: Bool = false
    ) -> HomePinnedRowAction {
        if hasUnresolvedCommand { return .checkReceipt }
        guard let status else { return .unavailable }
        switch status.phase {
        case .undesignated, .disabled, .missingSession:
            return .designate
        case .unavailable:
            return .unavailable
        case .ready, .active, .blocked, .paused, .rolloverPending:
            // `openSessionId` is the only route target: during a rollover it names
            // the sealed predecessor, because the reserved successor is not openable.
            guard status.enabled, let sessionID = status.openSessionId, !sessionID.isEmpty else { return .unavailable }
            return .open(sessionID: sessionID)
        }
    }
}

struct HomePinnedRow: View {
    let status: HomeStatusDTO?
    let isDesignating: Bool
    var hasUnresolvedCommand = false
    /// The mounted read reached a Gateway whose status could not be read or
    /// admitted; the row must not keep saying it is loading.
    var isStatusUnavailable = false

    private var action: HomePinnedRowAction {
        HomePinnedRowPolicy.action(for: status, hasUnresolvedCommand: hasUnresolvedCommand)
    }
    private var detail: String {
        if isDesignating { return hasUnresolvedCommand ? "Checking Home change…" : "Setting up Home…" }
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
        if isDesignating { return hasUnresolvedCommand ? "Checking" : "Setting up" }
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
            if isDesignating {
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
