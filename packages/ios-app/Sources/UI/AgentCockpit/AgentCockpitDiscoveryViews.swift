import SwiftUI

struct CapabilitiesSummaryCard: View {
    let overview: AgentCockpitDiscoveryOverview
    let currentRevision: UInt64?
    let onVerify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: overview.systemImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summaryTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(summaryDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onVerify) {
                    Label("Check capabilities", systemImage: "checkmark.shield")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.18)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                capabilityMetric("Areas", overview.groups.count)
                capabilityMetric("Operations", operationMetricCount)
                capabilityMetric("Workers", overview.workerCount)
                capabilityMetric("Triggers", overview.triggerCount)
            }
            if currentRevision != nil || overview.latestReport != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let version = AgentCockpitPresentation.capabilityMapRevision(currentRevision) {
                        Text(version)
                    }
                    if let checked = AgentCockpitPresentation.safeLastChecked(overview.latestReport) {
                        Text("Last checked \(checked)")
                    }
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var summaryTitle: String {
        AgentCockpitPresentation.verificationTitle(for: overview)
    }

    private var summaryDetail: String {
        AgentCockpitPresentation.verificationDetail(for: overview)
    }

    private var operationMetricCount: Int {
        overview.capabilityVisibility?.operationList.totalOperations
            ?? (overview.operationCount > 0 ? overview.operationCount : overview.functionCount)
    }

    private var statusColor: Color {
        switch overview.title {
        case "Verified":
            return .tronSuccess
        case "Catalog Degraded", "Capabilities Need Review", "Schema Gaps", "Attention", "Report Failed", "Verification Needs Review":
            return .tronWarning
        default:
            return .tronInfo
        }
    }

    private func capabilityMetric(_ title: String, _ value: Int) -> some View {
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

struct WorkerTriggerExplanationCard: View {
    let workers: Int
    let triggers: Int
    let operations: Int

    var body: some View {
        if operations > 0, workers == 0, triggers == 0 {
            Label(
                "Built-in engine operations can be invoked directly. Worker and trigger counts appear when modules publish autonomous runtime owners.",
                systemImage: "info.circle"
            )
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextSecondary)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(.tronInfo, cornerRadius: 10, subtle: true, interactive: false)
        }
    }
}

struct CapabilityGroupCard: View {
    let group: AgentCockpitCapabilityGroupRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: group.hasIssues ? "exclamationmark.triangle" : "square.stack.3d.up")
                    .foregroundStyle(group.hasIssues ? .tronWarning : .tronInfo)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(group.question)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    Text(group.narrative)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(2)
                }
                Spacer()
                Text(group.hasIssues ? "\(group.degradedCount + group.missingSchemaCount)" : "OK")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .countBadge(group.hasIssues ? .tronWarning : .tronInfo)
            }
            HStack(spacing: 8) {
                compactMetric(
                    AgentCockpitPresentation.groupMetricTitle(for: group, metric: .operations),
                    group.operationCount > 0 ? group.operationCount : group.functionCount
                )
                compactMetric(
                    AgentCockpitPresentation.groupMetricTitle(for: group, metric: .definitions),
                    group.functionCount
                )
                compactMetric(
                    AgentCockpitPresentation.groupMetricTitle(for: group, metric: .workers),
                    group.workerCount
                )
            }
            Text(group.ownerSummary)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
            if let explanation = group.workerTriggerExplanation {
                Text(explanation)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func compactMetric(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CatalogVerificationRow: View {
    let report: AgentCockpitDiscoveryReportRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isPassed ? "checkmark.shield" : "exclamationmark.shield")
                .foregroundStyle(isPassed ? .tronSuccess : .tronWarning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(isPassed ? "Capabilities check passed" : "Capabilities check needs review")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(AgentCockpitPresentation.safeTimestamp(report.updatedAt) ?? "Safe evidence recorded")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                Text("Evidence is available in the operation detail.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
            Spacer()
        }
        .padding(11)
        .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: false)
    }

    private var isPassed: Bool {
        AgentCockpitProjection.normalized(report.lifecycle) == "passed"
    }
}

struct CapabilityGroupDetailSheet: View {
    let group: AgentCockpitCapabilityGroupRow
    let latestReport: AgentCockpitDiscoveryReportRow?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOperation: AgentCockpitOperationRow?
    @State private var selectedFunction: AgentCockpitFunctionRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    if let explanation = group.workerTriggerExplanation {
                        Label(explanation, systemImage: "info.circle")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .padding(11)
                            .sectionFill(.tronInfo, cornerRadius: 10, subtle: true, interactive: false)
                    }
                    ForEach(group.operations) { operation in
                        Button {
                            selectedOperation = operation
                        } label: {
                            CapabilityOperationCard(operation: operation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("operation-row-\(operation.id)")
                    }
                    ForEach(group.functions) { function in
                        Button {
                            selectedFunction = function
                        } label: {
                            CapabilityFunctionCard(function: function)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("catalog-function-row-\(function.id)")
                    }
                    if let latestReport {
                        CatalogVerificationRow(report: latestReport)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("capability-group-detail-\(group.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: group.title, color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .sheet(item: $selectedOperation) { operation in
            CapabilityOperationDetailSheet(operation: operation, group: group, latestReport: latestReport)
        }
        .sheet(item: $selectedFunction) { function in
            OperationDetailSheet(operation: function, group: group, latestReport: latestReport)
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.question)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(group.narrative)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                detailMetric("Operations", group.operationCount)
                detailMetric("Contracts", group.functionCount)
                detailMetric("Workers", group.workerCount)
                detailMetric("Issues", group.degradedCount + group.missingSchemaCount)
            }
        }
        .padding(13)
        .sectionFill(group.hasIssues ? .tronWarning : .tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func detailMetric(_ title: String, _ value: Int) -> some View {
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

private struct CapabilityOperationCard: View {
    let operation: AgentCockpitOperationRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(operation.name)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(operation.ownerLabel) · \(operation.statusLabel)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
                Text(activitySummary)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(tint, cornerRadius: 10, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var activitySummary: String {
        if operation.activityCount > 0 {
            return "\(operation.bindingRequested) binding, \(operation.shadowRuns) shadow runs, \(operation.readinessLabel.lowercased())"
        }
        return "\(operation.readinessLabel) · \(operation.readinessNextActionLabel)"
    }

    private var symbol: String {
        if operation.isLocked { return "lock.shield" }
        if operation.isModuleOwned { return "shippingbox" }
        if operation.canReplace { return "arrow.triangle.2.circlepath" }
        return "doc.text.magnifyingglass"
    }

    private var tint: Color {
        if operation.isLocked { return .tronTextMuted }
        if operation.canReplace { return .tronInfo }
        return .tronEmerald
    }
}

private struct CapabilityFunctionCard: View {
    let function: AgentCockpitFunctionRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: function.schemaComplete ? "checkmark.circle" : "doc.badge.gearshape")
                .foregroundStyle(function.schemaComplete ? .tronSuccess : .tronWarning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(operationName)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(function.description.nilIfEmpty ?? "No provider-visible description is published.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
                Text("\(schemaStatus) · \(riskSummary)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(function.schemaComplete ? .tronEmerald : .tronWarning, cornerRadius: 10, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var operationName: String {
        function.id
    }

    private var schemaStatus: String {
        function.schemaComplete ? "Schema complete" : "Schema needs review"
    }

    private var riskSummary: String {
        "\(AgentCockpitPresentation.displayLabel(function.riskLevel)) risk"
    }
}
