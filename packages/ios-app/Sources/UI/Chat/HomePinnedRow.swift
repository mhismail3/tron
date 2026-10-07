import SwiftUI
import TronMobileCore

// Home does not appear in the ordinary session catalog. Its explicit states
// keep unavailable and stale session identities from becoming route targets.
enum HomePinnedRowAction: Equatable {
    case designate
    case open(sessionID: String)
    case unavailable
}

enum HomePinnedRowPolicy {
    static func action(for status: HomeStatusDTO?) -> HomePinnedRowAction {
        guard let status else { return .unavailable }
        switch status.phase {
        case .undesignated, .disabled, .missingSession:
            return .designate
        case .unavailable:
            return .unavailable
        case .ready, .active, .blocked:
            guard status.enabled, status.sessionPresent,
                  let sessionID = status.sessionId, !sessionID.isEmpty else { return .unavailable }
            return .open(sessionID: sessionID)
        }
    }
}

struct HomePinnedRow: View {
    let status: HomeStatusDTO?
    let isDesignating: Bool

    private var action: HomePinnedRowAction { HomePinnedRowPolicy.action(for: status) }
    private var detail: String {
        if isDesignating { return "Setting up Home…" }
        guard let status else { return "Loading Home status…" }
        switch status.phase {
        case .undesignated: return "Set up your Home session"
        case .disabled: return "Disabled · Tap to re-enable"
        case .missingSession: return "Session missing · Tap to restore"
        case .blocked: return "Home session · Open chat"
        case .active: return "Active"
        case .ready: return "Ready"
        case .unavailable: return status.reason ?? "Home is unavailable"
        }
    }

    private var trailing: String {
        if isDesignating { return "Setting up" }
        switch action {
        case .designate: return "Set up"
        case .open: return status?.phase == .active ? "Active" : "Ready"
        case .unavailable: return status == nil ? "Loading" : "Unavailable"
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
            .font(.system(size: 22, weight: .semibold))
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
