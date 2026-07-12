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
                        briefingMetric(overview.invokableUnitLabel, "\(overview.invokableUnitCount)")
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
        if overview.status.kind == .offline {
            return "No active engine link. Connect a server to inspect core health."
        }
        if issueCount > 0 {
            return "Engine link is up, but \(issueCount) capability issue\(issueCount == 1 ? "" : "s") need review."
        }
        switch overview.status.kind {
        case .connecting:
            return "Connecting to the engine so core health and capabilities can be checked."
        case .degraded:
            return "\(overview.status.title): open the cockpit for safe diagnostics and evidence."
        case .awaitingApproval:
            return "Engine link is up, and one item is waiting for your review."
        case .running:
            return "Engine work is active. Open the cockpit for current activity."
        case .ready:
            return "Engine link is healthy and capabilities are available."
        case .idle:
            return "Engine link is healthy. No engine work is currently active."
        case .offline:
            return "No active engine link. Connect a server to inspect core health."
        }
    }

    private var issueCount: Int {
        overview.discovery.missingSchemaCount
            + overview.discovery.degradedFunctionCount
            + overview.discovery.catalogDecodeIssueCount
    }

    private var verificationPhrase: String {
        AgentCockpitPresentation.verificationPhrase(for: overview.discovery.latestReport)
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
        HStack(alignment: .top, spacing: 8) {
            metric("Workers", value: "\(overview.workers.count)", icon: "cpu")
            metric(overview.invokableUnitLabel, value: "\(overview.invokableUnitCount)", icon: "curlybraces")
            metric("Issues", value: "\(issueCount)", icon: "exclamationmark.triangle")
            metric("Capability check", value: verificationMetricValue, icon: "checkmark.shield")
        }
    }

    private var issueCount: Int {
        overview.discovery.missingSchemaCount
            + overview.discovery.degradedFunctionCount
            + overview.discovery.catalogDecodeIssueCount
    }

    private var verificationMetricValue: String {
        AgentCockpitPresentation.verificationPhrase(for: overview.discovery.latestReport)
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
                .lineLimit(2)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .sectionFill(.tronEmerald, cornerRadius: 8, subtle: true, interactive: false)
    }
}
