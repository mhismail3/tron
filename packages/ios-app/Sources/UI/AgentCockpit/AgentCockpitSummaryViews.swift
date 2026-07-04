import SwiftUI

struct EngineCockpitDashboardBand: View {
    let overview: AgentCockpitOverview
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: overview.status.systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Engine Cockpit")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(summary)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        briefingMetric("Capabilities", "\(overview.functions.count)")
                        briefingMetric("Issues", "\(issueCount)")
                        briefingPhrase(verificationPhrase)
                    }
                }

                Spacer(minLength: 8)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("engine-cockpit-dashboard-band")
        .accessibilityLabel("Engine Cockpit")
    }

    private var summary: String {
        AgentCockpitPresentation.dashboardSummary(for: overview)
    }

    private var issueCount: Int {
        AgentCockpitPresentation.issueCount(for: overview)
    }

    private var verificationPhrase: String {
        AgentCockpitPresentation.dashboardVerificationPhrase(for: overview.discovery.latestReport)
    }

    private var accent: Color {
        switch overview.status.kind {
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

struct AgentCockpitMetricStrip: View {
    let overview: AgentCockpitOverview

    var body: some View {
        HStack(spacing: 8) {
            metric("Readiness", value: "\(overview.workers.count)", icon: "cpu")
            metric("Capabilities", value: "\(overview.functions.count)", icon: "curlybraces")
            metric("Issues", value: "\(issueCount)", icon: "exclamationmark.triangle")
            metric("Verification", value: verificationStatus, icon: "checkmark.shield")
        }
    }

    private var issueCount: Int {
        AgentCockpitPresentation.issueCount(for: overview)
    }

    private var verificationStatus: String {
        AgentCockpitPresentation.verificationStatus(for: overview.discovery.latestReport)
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .sectionFill(.tronEmerald, cornerRadius: 8, subtle: true, interactive: false)
    }
}
