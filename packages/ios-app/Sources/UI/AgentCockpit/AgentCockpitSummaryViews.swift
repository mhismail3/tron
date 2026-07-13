import SwiftUI

struct EngineCockpitDashboardBand: View {
    let overview: AgentCockpitOverview
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: SessionListLayout.iconTextSpacing) {
                Image(systemName: dashboardSummary.systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(
                        width: SessionListLayout.iconColumnWidth,
                        height: SessionListLayout.iconColumnWidth
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Dashboard")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(dashboardSummary.detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        briefingMetric("Actions", dashboardSummary.agentActions.displayValue)
                        briefingMetric("Triggers", "\(dashboardSummary.triggers)")
                        briefingMetric("Issues", "\(dashboardSummary.issues)")
                        briefingPhrase(dashboardSummary.verification)
                    }
                }

                Spacer(minLength: 8)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                }
            }
            .padding(.horizontal, SessionListLayout.rowContentHorizontalPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("engine-cockpit-dashboard-band")
        .accessibilityLabel("Dashboard")
    }

    private var dashboardSummary: AgentCockpitDashboardSummary {
        AgentCockpitPresentation.dashboardSummary(for: overview)
    }

    private var accent: Color {
        if dashboardSummary.issues > 0 {
            return .tronWarning
        }
        switch dashboardSummary.statusKind {
        case .degraded:
            return .tronError
        case .awaitingApproval:
            return .tronWarning
        case .running:
            return .tronCyan
        case .offline, .connecting:
            return .tronTextMuted
        case .idle, .ready:
            return .tronEmerald
        }
    }

    private func briefingMetric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(accent)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }

    private func briefingPhrase(_ value: String) -> some View {
        Text(value)
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }
}

struct AgentCockpitDashboardSummaryCard: View {
    let overview: AgentCockpitOverview
    let onVerify: () -> Void

    private let summaryIconColumnWidth: CGFloat = 22
    private let summaryIconTextSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: summaryIconTextSpacing) {
                Image(systemName: summary.systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: summaryIconColumnWidth, height: summaryIconColumnWidth)
                Text(summary.title)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Spacer(minLength: 0)
                if summary.issues > 0 {
                    Label(
                        "\(summary.issues) issue\(summary.issues == 1 ? "" : "s")",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronWarning)
                }
            }
            Text(summary.detail)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, summaryTextLeadingInset)
                .padding(.top, 3)

            summaryDivider

            summaryRow(
                title: "Capabilities",
                value: summary.agentActions.phrase(
                    singular: "agent action",
                    plural: "agent actions"
                ),
                detail: "\(summary.verification) · \(workerPhrase) · \(triggerPhrase)",
                icon: "sparkles",
                iconColor: .tronEmerald,
                identifier: "dashboard-summary-capabilities",
                trailingAction: { verifyButton }
            )

            summaryDivider

            summaryRow(
                title: "Engine",
                value: summary.engineActions.phrase(
                    singular: "engine action",
                    plural: "engine actions"
                ),
                detail: engineInterfacePhrase,
                icon: "gearshape.2",
                iconColor: .tronInfo,
                identifier: "dashboard-summary-engine"
            )

            summaryDivider

            summaryRow(
                title: "Recent activity",
                value: summary.recentActivityTitle,
                detail: activityDetail,
                icon: "waveform.path.ecg",
                iconColor: statusColor,
                identifier: "dashboard-summary-activity"
            )
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var summary: AgentCockpitDashboardSummary {
        AgentCockpitPresentation.dashboardSummary(for: overview)
    }

    private var summaryTextLeadingInset: CGFloat {
        summaryIconColumnWidth + summaryIconTextSpacing
    }

    private var verifyButton: some View {
        Button(action: onVerify) {
            Label("Check", systemImage: "checkmark.shield")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.18)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Check capabilities")
    }

    private var activityDetail: String {
        var facts: [String] = []
        if summary.activeActivity > 0 { facts.append("\(summary.activeActivity) active") }
        if summary.waitingActivity > 0 { facts.append("\(summary.waitingActivity) waiting") }
        if summary.blockedActivity > 0 { facts.append("\(summary.blockedActivity) blocked") }
        if summary.degradedActivity > 0 { facts.append("\(summary.degradedActivity) degraded") }
        return facts.isEmpty
            ? "Nothing is waiting or blocked."
            : facts.joined(separator: " · ")
    }

    private var workerPhrase: String {
        AgentCockpitPresentation.countPhrase(
            summary.workers,
            singular: "worker",
            plural: "workers"
        )
    }

    private var triggerPhrase: String {
        AgentCockpitPresentation.countPhrase(
            summary.triggers,
            singular: "trigger",
            plural: "triggers"
        )
    }

    private var engineInterfacePhrase: String {
        AgentCockpitPresentation.countPhrase(
            summary.engineInterfaces,
            singular: "engine interface",
            plural: "engine interfaces"
        )
    }

    private var summaryDivider: some View {
        Divider()
            .overlay(Color.tronBorder.opacity(0.7))
            .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch summary.statusKind {
        case .offline, .connecting:
            return .tronTextMuted
        case .idle, .ready:
            return .tronInfo
        case .running:
            return .tronCyan
        case .awaitingApproval:
            return .tronWarning
        case .degraded:
            return .tronError
        }
    }

    private func summaryRow(
        title: String,
        value: String,
        detail: String,
        icon: String,
        iconColor: Color,
        identifier: String
    ) -> some View {
        summaryRow(
            title: title,
            value: value,
            detail: detail,
            icon: icon,
            iconColor: iconColor,
            identifier: identifier,
            trailingAction: EmptyView.init
        )
    }

    private func summaryRow<TrailingAction: View>(
        title: String,
        value: String,
        detail: String,
        icon: String,
        iconColor: Color,
        identifier: String,
        @ViewBuilder trailingAction: () -> TrailingAction
    ) -> some View {
        HStack(alignment: .top, spacing: summaryIconTextSpacing) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: summaryIconColumnWidth, height: summaryIconColumnWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(value)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingAction()
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }
}
