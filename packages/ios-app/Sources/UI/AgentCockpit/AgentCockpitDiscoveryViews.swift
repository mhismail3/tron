import SwiftUI

struct DiscoverySummaryCard: View {
    let overview: AgentCockpitDiscoveryOverview
    let onVerify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: overview.systemImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(overview.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(overview.detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                Button(action: onVerify) {
                    Label("Verify", systemImage: "checkmark.shield")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.18)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                discoveryMetric("Namespaces", overview.namespaceCount)
                discoveryMetric("Triggers", overview.triggerCount)
                discoveryMetric("Types", overview.triggerTypeCount)
            }
            if let latest = overview.latestReport {
                Text("Latest \(latest.lifecycle) · \(latest.updatedAt ?? latest.resourceId)")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var statusColor: Color {
        switch overview.title {
        case "Verified":
            return .tronSuccess
        case "Schema Gaps", "Attention", "Report Failed":
            return .tronWarning
        default:
            return .tronInfo
        }
    }

    private func discoveryMetric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapabilityFamilyCard: View {
    let family: AgentCockpitCapabilityFamilyRow

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: family.missingSchemaCount > 0 || family.degradedCount > 0 ? "exclamationmark.triangle" : "square.stack.3d.up")
                    .foregroundStyle(family.missingSchemaCount > 0 || family.degradedCount > 0 ? .tronWarning : .tronInfo)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.id)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(family.functionCount) functions · \(family.workerCount) workers · \(family.triggerCount) triggers")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                Text("\(family.missingSchemaCount + family.degradedCount)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .countBadge(family.missingSchemaCount + family.degradedCount > 0 ? .tronWarning : .tronInfo)
            }
            if !family.effectClasses.isEmpty {
                WrapRow(items: Array((family.effectClasses + family.riskLevels).prefix(4)), tint: .tronInfo)
            }
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }
}

struct DiscoveryReportRow: View {
    let report: AgentCockpitDiscoveryReportRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: normalized(report.lifecycle) == "passed" ? "checkmark.shield" : "exclamationmark.shield")
                .foregroundStyle(normalized(report.lifecycle) == "passed" ? .tronSuccess : .tronWarning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.lifecycle)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(report.resourceId)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let updatedAt = report.updatedAt {
                    Text(updatedAt)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }
            Spacer()
        }
        .padding(11)
        .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: false)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }
}
