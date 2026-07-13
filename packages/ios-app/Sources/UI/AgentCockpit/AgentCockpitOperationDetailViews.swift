import SwiftUI

struct CapabilityOperationDetailSheet: View {
    let operation: AgentCockpitOperationRow
    let group: AgentCockpitCapabilityGroupRow
    let latestReport: AgentCockpitDiscoveryReportRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    role
                    agentUse
                    ownership
                    readiness
                    replacement
                    route
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

    private var role: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Role")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("Audience", AgentCockpitPresentation.capabilityAudienceLabel(operation.capabilityAudience))
            detailRow("Runtime ownership", AgentCockpitPresentation.capabilityReplacementClassLabel(operation.capabilityReplacementClass))
            detailRow("Agent access", AgentCockpitPresentation.capabilityVisibilityLabel(operation.capabilityDefaultVisibility))
            detailRow("Future path", AgentCockpitPresentation.capabilityMinimalityLabel(operation.capabilityMinimalityDecision))
            Text(roleNarrative)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(roleTint, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var agentUse: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Use")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("Callable", operation.agentUsageCallable ? "Yes" : "Inspect only")
            detailRow("Tool", operation.agentUsageTool)
            detailRow("Operation", operation.agentUsageOperation)
            detailRow("Use", AgentCockpitPresentation.displayLabel(operation.agentUsageDefaultUse))
            Text(operation.agentUsagePreflight)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(operation.agentUsageRecovery)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(.tronInfo, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(operation.statusLabel, systemImage: operation.isLocked ? "lock.shield" : "checkmark.shield")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(operation.isLocked ? .tronTextMuted : .tronSuccess)
            Text(operation.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(operation.description)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(group.title) · \(operation.readinessLabel)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            Text("Operation ID: \(operation.name)")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
                .textSelection(.enabled)
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
            detailRow("Defined by", AgentCockpitPresentation.provenanceLabel(operation.metadataSourceLabel))
            detailRow("Shown from", AgentCockpitPresentation.provenanceLabel(operation.projectionSourceLabel))
            detailRow("Family", operation.familyLabel)
            detailRow("Status", operation.statusLabel)
            Text(operation.ownerDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(operation.statusDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
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
            if let latest = AgentCockpitPresentation.safeTimestamp(operation.bindingLastUpdatedAt) ?? operation.bindingLatestState.map(AgentCockpitPresentation.displayLabel) {
                detailRow("Binding latest", latest)
            }
            if let latest = AgentCockpitPresentation.safeTimestamp(operation.shadowLastUpdatedAt) ?? operation.shadowLatestState.map(AgentCockpitPresentation.displayLabel) {
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

    private var route: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runtime Route")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            detailRow("State", operation.routeLabel)
            detailRow("Active", "\(operation.activeRoutes)")
            detailRow("Events", "\(operation.routeEvents)")
            detailRow("Invocations", "\(operation.routedInvocations)")
            detailRow("Failed closed", "\(operation.routeFailedClosed)")
            detailRow("Disabled", "\(operation.routeDisabled)")
            detailRow("Rolled back", "\(operation.routeRolledBack)")
            if let latest = AgentCockpitPresentation.safeTimestamp(operation.routeLastUpdatedAt) ?? operation.routeLatestState.map(AgentCockpitPresentation.displayLabel) {
                detailRow("Latest", latest)
            }
            Text(operation.routeDetail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .sectionFill(routeTint, cornerRadius: 12, subtle: true, interactive: false)
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

    private var routeTint: Color {
        switch operation.routeState {
        case "active":
            return .tronSuccess
        case "failed_closed":
            return .tronWarning
        case "disabled", "rolled_back":
            return .tronInfo
        default:
            return .tronEmerald
        }
    }

    private var roleTint: Color {
        switch AgentCockpitProjection.normalized(operation.capabilityReplacementClass) {
        case "runtimeroutable":
            return .tronInfo
        case "producerextensible":
            return .tronEmerald
        case "kernelevolutiononly":
            return .tronTextMuted
        default:
            return .tronEmerald
        }
    }

    private var roleNarrative: String {
        let audience = AgentCockpitPresentation.capabilityAudienceLabel(operation.capabilityAudience).lowercased()
        switch AgentCockpitProjection.normalized(operation.capabilityReplacementClass) {
        case "runtimeroutable":
            return "This is \(audience). A governed module can become the runtime owner only after validation, shadow evidence, approval, activation, and rollback proof."
        case "producerextensible":
            return "This is \(audience). Modules may add producers or richer workflows, but server-owned custody and redaction remain the source of truth."
        case "kernelevolutiononly":
            return "This is \(audience). It can improve through source-level kernel evolution, review, validation, and integration; it is not a live runtime route."
        default:
            return "This operation has a server-owned role classification. Inspect evidence before inferring how it can evolve."
        }
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
            return "The latest capability check passed at \(AgentCockpitPresentation.safeTimestamp(latestReport.updatedAt) ?? "the recorded evidence time")."
        }
        if lifecycle == "failed" || lifecycle == "quarantined" {
            return "The latest capability check needs review before trusting this operation snapshot."
        }
        return "Capability check state: \(AgentCockpitPresentation.displayLabel(latestReport.lifecycle))."
    }
}

struct OperationDetailSheet: View {
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
            Text(AgentCockpitPresentation.functionDisplayName(operation.id))
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(operation.description.nilIfEmpty ?? "No provider-visible description is published.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Part of \(group.title).")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            Text("Function ID: \(operation.id)")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
                .textSelection(.enabled)
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
            detailRow("Visibility", AgentCockpitPresentation.displayLabel(operation.visibility))
            detailRow("Effect", AgentCockpitPresentation.displayLabel(operation.effectClass))
            detailRow("Risk", AgentCockpitPresentation.displayLabel(operation.riskLevel))
            detailRow("Health", AgentCockpitPresentation.displayLabel(operation.health))
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
                Text("Provider-visible contract from the live operation catalog.")
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
            AgentCockpitPresentation.displayLabel(operation.effectClass),
            "\(AgentCockpitPresentation.displayLabel(operation.riskLevel)) risk",
            AgentCockpitPresentation.displayLabel(operation.health),
            schemaStatus
        ]
        let publishedTags = operation.tags.map(AgentCockpitPresentation.displayLabel)
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
        return "Capability check state: \(AgentCockpitPresentation.displayLabel(latestReport.lifecycle))."
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
