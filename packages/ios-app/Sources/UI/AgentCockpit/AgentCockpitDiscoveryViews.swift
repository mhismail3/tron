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
                Text(safeTimestamp(report.updatedAt) ?? "Safe evidence recorded")
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
        .sectionFill(tint, cornerRadius: 10, subtle: true, interactive: true)
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
        .sectionFill(function.schemaComplete ? .tronEmerald : .tronWarning, cornerRadius: 10, subtle: true, interactive: true)
    }

    private var operationName: String {
        function.id
    }

    private var schemaStatus: String {
        function.schemaComplete ? "Schema complete" : "Schema needs review"
    }

    private var riskSummary: String {
        "\(standardized(function.riskLevel)) risk"
    }
}

private struct CapabilityOperationDetailSheet: View {
    let operation: AgentCockpitOperationRow
    let group: AgentCockpitCapabilityGroupRow
    let latestReport: AgentCockpitDiscoveryReportRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    ownership
                    readiness
                    replacement
                    attempts
                    rollback
                    verification
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Operation Detail", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .accessibilityIdentifier("operation-detail-\(operation.id)")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(operation.statusLabel, systemImage: operation.isLocked ? "lock.shield" : "checkmark.shield")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(operation.isLocked ? .tronTextMuted : .tronSuccess)
            Text(operation.name)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
            Text(operation.statusDetail)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Part of \(group.title).")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            Text(operation.readinessLabel)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(13)
        .sectionFill(operation.isLocked ? .tronTextMuted : .tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var ownership: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ownership")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("Owner now", operation.ownerLabel)
            detailRow("Metadata source", operation.metadataSourceLabel)
            detailRow("Projection source", operation.projectionSourceLabel)
            detailRow("Family", operation.familyLabel)
            detailRow("Status", operation.statusLabel)
            Text(operation.ownerDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Readiness")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("State", operation.readinessLabel)
            detailRow("Next", operation.readinessNextActionLabel)
            Text(operation.readinessDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(operation.readinessNextActionDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(.tronInfo, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var replacement: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Replacement")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("Policy", operation.replacementLabel)
            detailRow("Target", operation.replacementTargetLabel)
            detailRow("Boundary", operation.governanceBoundary)
            WrapRow(items: replacementChips, tint: .tronInfo)
            Text(operation.replacementDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(operation.replacementTargetDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var attempts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attempts")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("Binding", "\(operation.bindingRequested) requested, \(operation.bindingApproved) approved, \(operation.bindingRejected) rejected")
            detailRow("Failed replacements", "\(operation.failedReplacementAttempts)")
            detailRow("Shadow trial", "\(operation.shadowRequested) requested, \(operation.shadowApproved) approved, \(operation.shadowRuns) run")
            detailRow("Shadow result", "\(operation.shadowPassed) passed, \(operation.shadowFailed) failed")
            if let latest = safeTimestamp(operation.bindingLastUpdatedAt) ?? operation.bindingLatestState.map(standardized) {
                detailRow("Binding latest", latest)
            }
            if let latest = safeTimestamp(operation.shadowLastUpdatedAt) ?? operation.shadowLatestState.map(standardized) {
                detailRow("Shadow latest", latest)
            }
            Text(operation.bindingDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(operation.shadowDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(operation.failedReplacementAttempts > 0 || operation.shadowFailed > 0 ? .tronWarning : .tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var rollback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rollback")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("Rollback", operation.rollbackAvailable ? "Available" : "Not active")
            detailRow("Disable", operation.disableAvailable ? "Available" : "Not active")
            detailRow("Abort", operation.abortAvailable ? "Available" : "Not active")
            detailRow("Boundary", operation.rollbackBoundary)
            Text(operation.rollbackDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(operation.rollbackAvailable ? .tronSuccess : .tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(verificationCopy)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var replacementChips: [String] {
        [
            operation.canShadow ? "Shadow allowed" : "No shadow",
            operation.canReplace ? "Replace allowed" : "No replace",
            operation.canExtend ? "Extend allowed" : "No extend"
        ]
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 12)
            Text(value.nilIfEmpty ?? "Not published")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    private var verificationCopy: String {
        guard let latestReport else {
            return "No capability verification evidence has been published yet."
        }
        let lifecycle = AgentCockpitProjection.normalized(latestReport.lifecycle)
        if lifecycle == "passed" {
            return "The latest capability check passed at \(safeTimestamp(latestReport.updatedAt) ?? "the recorded evidence time")."
        }
        if lifecycle == "failed" || lifecycle == "quarantined" {
            return "The latest capability check needs review before trusting this operation snapshot."
        }
        return "Capability check state: \(standardized(latestReport.lifecycle))."
    }
}

private struct OperationDetailSheet: View {
    let operation: AgentCockpitFunctionRow
    let group: AgentCockpitCapabilityGroupRow
    let latestReport: AgentCockpitDiscoveryReportRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    schemaSection
                    metadata
                    if !detailTags.isEmpty {
                        tagSection
                    }
                    verification
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Operation Detail", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .accessibilityIdentifier("operation-detail-\(operation.id)")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(schemaStatus, systemImage: operation.schemaComplete ? "checkmark.circle" : "doc.badge.gearshape")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(operation.schemaComplete ? .tronSuccess : .tronWarning)
            Text(operation.id)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
            Text(operation.description.nilIfEmpty ?? "No provider-visible description is published.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Part of \(group.title).")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(13)
        .sectionFill(operation.schemaComplete ? .tronEmerald : .tronWarning, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How Tron Sees It")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("Owner", operation.ownerWorker)
            detailRow("Visibility", standardized(operation.visibility))
            detailRow("Effect", standardized(operation.effectClass))
            detailRow("Risk", standardized(operation.riskLevel))
            detailRow("Health", standardized(operation.health))
            detailRow("Schema", schemaStatus)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            WrapRow(items: detailTags, tint: .tronEmerald)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var schemaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Schema")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text("Provider-visible contract from the live capability map.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
            SchemaBlock(
                title: "Request",
                status: operation.requestSchemaPresent ? "Published" : "Missing",
                json: operation.requestSchemaJSON,
                tint: operation.requestSchemaPresent ? .tronEmerald : .tronWarning
            )
            if operation.opaqueResponse, operation.responseSchemaJSON == nil {
                SchemaBlock(
                    title: "Response",
                    status: "Opaque response declared",
                    json: nil,
                    tint: .tronInfo
                )
            } else {
                SchemaBlock(
                    title: "Response",
                    status: operation.responseSchemaPresent ? "Published" : "Missing",
                    json: operation.responseSchemaJSON,
                    tint: operation.responseSchemaPresent ? .tronEmerald : .tronWarning
                )
            }
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(verificationCopy)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 12)
            Text(value.nilIfEmpty ?? "Not published")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var schemaStatus: String {
        operation.schemaComplete ? "Schema complete" : "Schema needs review"
    }

    private var detailTags: [String] {
        let metadataTags = [
            standardized(operation.effectClass),
            "\(standardized(operation.riskLevel)) risk",
            standardized(operation.health),
            schemaStatus
        ]
        let publishedTags = operation.tags.map(standardized)
        return Array((metadataTags + publishedTags).filter { !$0.isEmpty }.prefix(10))
    }

    private var verificationCopy: String {
        guard let latestReport else {
            return "No capability verification evidence has been published yet."
        }
        let lifecycle = AgentCockpitProjection.normalized(latestReport.lifecycle)
        if lifecycle == "passed" {
            return "The latest capability check passed. Safe evidence is available from the verification detail."
        }
        if lifecycle == "failed" || lifecycle == "quarantined" {
            return "The latest capability check needs review before trusting this capability snapshot."
        }
        return "Capability check state: \(standardized(latestReport.lifecycle))."
    }
}

private struct SchemaBlock: View {
    let title: String
    let status: String
    let json: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(status)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            if let json, !json.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(json)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(Color.tronSurface.opacity(0.22)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("No schema body is available in the latest capability snapshot.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(10)
        .sectionFill(tint, cornerRadius: 10, subtle: true, interactive: false)
    }
}

private func standardized(_ value: String) -> String {
    splitCamelCase(value)
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(separator: " ")
        .map { word in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
}

private func splitCamelCase(_ value: String) -> String {
    var output = ""
    var previous: Character?
    for character in value {
        if let previous,
           character.isUppercase,
           previous.isLowercase || previous.isNumber {
            output.append(" ")
        }
        output.append(character)
        previous = character
    }
    return output
}

private func safeTimestamp(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
        .replacingOccurrences(of: "T", with: " ")
        .replacingOccurrences(of: "Z", with: "")
}
