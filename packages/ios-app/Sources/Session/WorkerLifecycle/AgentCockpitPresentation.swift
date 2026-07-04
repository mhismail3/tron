import Foundation

enum AgentCockpitPresentation {
    static let primaryTerms = ["Capabilities", "Verification", "Readiness", "Activity", "Audit"]

    static func issueCount(for overview: AgentCockpitOverview) -> Int {
        overview.discovery.missingSchemaCount
            + overview.discovery.degradedFunctionCount
            + overview.discovery.catalogDecodeIssueCount
    }

    static func dashboardSummary(for overview: AgentCockpitOverview) -> String {
        let issues = issueCount(for: overview)
        if overview.status.kind == .offline {
            return "No active engine link. Connect a server to inspect readiness."
        }
        if issues > 0 {
            return "Engine link is up, but \(issues) readiness issue\(issues == 1 ? "" : "s") need review."
        }
        switch overview.status.kind {
        case .connecting:
            return "Connecting to the engine so capabilities and readiness can be checked."
        case .degraded:
            return "\(overview.status.title): open the cockpit for readiness and audit details."
        case .awaitingApproval:
            return "Engine link is up, and one item is waiting for your review."
        case .running:
            return "Engine work is active. Open the cockpit for current activity."
        case .ready:
            return "Engine link is healthy and capabilities are ready."
        case .idle:
            return "Engine link is healthy. No engine work is currently active."
        case .offline:
            return "No active engine link. Connect a server to inspect readiness."
        }
    }

    static func headerDetail(for status: AgentCockpitStatusKind) -> String {
        switch status {
        case .connecting:
            return "Rebuilding the engine link."
        case .degraded:
            return "Open the cockpit sections for Readiness, Activity, and Audit."
        case .awaitingApproval:
            return "One item is waiting for your review."
        case .running:
            return "Engine or module work is currently active."
        case .ready:
            return "Core link is healthy and capabilities are available."
        case .idle:
            return "No engine or module work is currently active."
        case .offline:
            return "Connect a server to inspect readiness."
        }
    }

    static func verificationStatus(for latestReport: AgentCockpitDiscoveryReportRow?) -> String {
        guard let latestReport else {
            return "Unchecked"
        }
        switch AgentCockpitProjection.normalized(latestReport.lifecycle) {
        case "passed":
            return "Verified"
        case "failed", "quarantined":
            return "Needs Review"
        default:
            return readableLabel(latestReport.lifecycle)
        }
    }

    static func dashboardVerificationPhrase(for latestReport: AgentCockpitDiscoveryReportRow?) -> String {
        switch verificationStatus(for: latestReport) {
        case "Verified":
            return "Verification passed"
        case "Needs Review":
            return "Verification needs review"
        case "Unchecked":
            return "Not yet verified"
        case let status:
            return "Verification \(status.lowercased())"
        }
    }

    static func discoverySummaryTitle(for overview: AgentCockpitDiscoveryOverview) -> String {
        switch overview.title {
        case "Verified":
            return "Capabilities verified"
        case "No Catalog":
            return "No capabilities published"
        case "Catalog Degraded", "Report Failed":
            return "Verification needs review"
        case "Schema Gaps":
            return "Readiness needs review"
        default:
            return overview.title
        }
    }

    static func discoverySummaryDetail(for overview: AgentCockpitDiscoveryOverview) -> String {
        if overview.functionCount == 0, overview.operationCount == 0 {
            return "No visible capabilities are available from the connected engine."
        }
        if let operationList = overview.capabilityVisibility?.operationList, operationList.truncated {
            return "\(operationList.returnedOperations) of \(operationList.totalOperations) capabilities are visible. \(operationList.label)."
        }
        if let resourceScan = overview.capabilityVisibility?.resourceScan, resourceScan.truncated {
            return "\(visibleCapabilityCount(for: overview)) capabilities are visible. \(resourceScan.label)."
        }
        if overview.catalogDecodeIssueCount > 0 {
            return "\(overview.catalogDecodeIssueCount) verification issue\(overview.catalogDecodeIssueCount == 1 ? "" : "s") need review."
        }
        if overview.missingSchemaCount > 0 {
            return "\(overview.missingSchemaCount) capabilities need readiness details."
        }
        if overview.degradedFunctionCount > 0 {
            return "\(overview.degradedFunctionCount) capabilities need attention."
        }
        return "\(visibleCapabilityCount(for: overview)) capabilities are visible across \(overview.groups.count) areas."
    }

    static func visibleCapabilityCount(for overview: AgentCockpitDiscoveryOverview) -> Int {
        overview.operationCount > 0 ? overview.operationCount : overview.functionCount
    }

    static func operationMetricCount(for overview: AgentCockpitDiscoveryOverview) -> Int {
        overview.capabilityVisibility?.operationList.totalOperations
            ?? visibleCapabilityCount(for: overview)
    }

    static func snapshotLine(currentRevision: UInt64?) -> String? {
        guard currentRevision != nil else { return nil }
        return "Capability snapshot ready"
    }

    static func latestVerificationLine(_ latestReport: AgentCockpitDiscoveryReportRow?) -> String? {
        guard let latestReport else { return nil }
        if let timestamp = safeTimestamp(latestReport.updatedAt) {
            return "Last verified \(timestamp)"
        }
        return dashboardVerificationPhrase(for: latestReport)
    }

    static func workerTitle(_ worker: AgentCockpitWorkerRow) -> String {
        "\(readableIdentifier(worker.id, fallback: "Engine")) readiness"
    }

    static func workerSubtitle(_ worker: AgentCockpitWorkerRow) -> String {
        "\(readinessLabel(worker.lifecycle)) - \(countLabel(worker.functionCount, singular: "capability", plural: "capabilities")) - \(countLabel(worker.triggerCount, singular: "activity signal", plural: "activity signals"))"
    }

    static func workerChips(_ worker: AgentCockpitWorkerRow) -> [String] {
        [
            countLabel(worker.functionCount, singular: "Capability", plural: "Capabilities"),
            countLabel(worker.triggerCount, singular: "Activity signal", plural: "Activity signals")
        ]
    }

    static func packageTitle(_ package: AgentCockpitPackageRow) -> String {
        let title = readableIdentifier(package.packageId, fallback: "Capability package")
        if let version = package.packageVersion.nilIfEmpty {
            return "\(title) \(version)"
        }
        return title
    }

    static func packageSubtitle(_ package: AgentCockpitPackageRow) -> String {
        let kind = packageKindLabel(package.kind)
        let state = readinessLabel(package.lifecycle)
        return "\(kind) - \(state)"
    }

    static func packageAuditLine(_ package: AgentCockpitPackageRow) -> String {
        if safeTimestamp(package.updatedAt) != nil {
            return "Audit evidence recorded"
        }
        return "Audit evidence available after server verification"
    }

    static func activityStatusLine(_ item: AgentCockpitActivityItem) -> String {
        "\(readinessLabel(item.status)) activity"
    }

    static func activityAuditChips(_ item: AgentCockpitActivityItem) -> [String] {
        var chips: [String] = []
        if !item.authorityLabels.isEmpty {
            chips.append("Audit checked")
        }
        let touched = item.touchedResources.reduce(0) { $0 + $1.total }
        if touched > 0 {
            chips.append(countLabel(touched, singular: "Audit reference", plural: "Audit references"))
        }
        return chips
    }

    static func moduleActivityAuditChips(_ activity: ModuleActivityOverviewDTO) -> [String] {
        let total = activity.resources.reduce(0) { $0 + $1.total }
        guard total > 0 else { return [] }
        return [countLabel(total, singular: "Audit record", plural: "Audit records")]
    }

    static func topLevelVisibleStrings(for overview: AgentCockpitOverview) -> [String] {
        var strings = [
            "Engine Cockpit",
            dashboardSummary(for: overview),
            dashboardVerificationPhrase(for: overview.discovery.latestReport),
            overview.status.title,
            headerDetail(for: overview.status.kind),
            discoverySummaryTitle(for: overview.discovery),
            discoverySummaryDetail(for: overview.discovery),
            "Capabilities",
            "Verification",
            "Readiness",
            "Activity",
            "Audit"
        ]
        strings.append(contentsOf: [snapshotLine(currentRevision: overview.currentRevision), latestVerificationLine(overview.discovery.latestReport)].compactMap { $0 })
        for group in overview.discovery.groups {
            strings.append(contentsOf: [group.title, group.question, group.narrative, group.ownerSummary])
        }
        for worker in overview.workers {
            strings.append(workerTitle(worker))
            strings.append(workerSubtitle(worker))
            strings.append(contentsOf: workerChips(worker))
        }
        for package in overview.packages {
            strings.append(packageTitle(package))
            strings.append(packageSubtitle(package))
            strings.append(packageAuditLine(package))
        }
        if let moduleActivity = overview.moduleActivity {
            strings.append(moduleActivity.summary.title)
            strings.append(moduleActivity.summary.detail)
            strings.append(contentsOf: moduleActivityAuditChips(moduleActivity))
        }
        for item in overview.activity {
            strings.append(contentsOf: [item.title, item.detail, activityStatusLine(item)])
            strings.append(contentsOf: activityAuditChips(item))
        }
        return strings
    }

    static func topLevelLeakMatches(in value: String) -> [String] {
        let lowered = value.lowercased()
        return forbiddenTopLevelFragments.filter { lowered.contains($0) }
    }

    static func detailDisclosureStrings(for function: AgentCockpitFunctionRow) -> [String] {
        [
            function.description,
            function.ownerWorker,
            function.visibility,
            function.effectClass,
            function.riskLevel,
            function.health,
            function.requestSchemaJSON,
            function.responseSchemaJSON
        ].compactMap { $0?.nilIfEmpty } + function.tags
    }

    static func detailDisclosureStrings(for operation: AgentCockpitOperationRow) -> [String] {
        [
            operation.name,
            operation.ownerLabel,
            operation.ownerDetail,
            operation.metadataSourceLabel,
            operation.projectionSourceLabel,
            operation.statusLabel,
            operation.statusDetail,
            operation.replacementLabel,
            operation.replacementDetail,
            operation.replacementTargetLabel,
            operation.replacementTargetDetail,
            operation.governanceBoundary,
            operation.readinessLabel,
            operation.readinessDetail,
            operation.readinessNextActionLabel,
            operation.readinessNextActionDetail,
            operation.bindingDetail,
            operation.shadowDetail,
            operation.rollbackBoundary,
            operation.rollbackDetail
        ].compactMap { $0.nilIfEmpty }
    }

    private static let forbiddenTopLevelFragments = [
        "catalog",
        "resource:",
        "worker_package",
        "module_runtime_state",
        "catalog_discovery_report",
        "authority",
        "grant",
        "owner_actor",
        "authority_grant",
        "schema",
        "command",
        "raw ",
        "rev ",
        "revision",
        "::",
        "invocation",
        "trace",
        "domains::",
        "payload",
        "source:"
    ]

    private static func packageKindLabel(_ kind: WorkerLifecycleResourceKind) -> String {
        switch kind {
        case .proposal:
            return "Review"
        case .installation:
            return "Installed"
        case .launchAttempt:
            return "Activity"
        case .package:
            return "Package"
        case .conformanceReport, .catalogDiscoveryReport:
            return "Verification"
        case .uiSurface:
            return "Activity view"
        }
    }

    private static func readinessLabel(_ value: String) -> String {
        let readable = readableLabel(value)
        if readable.isEmpty {
            return "Unknown"
        }
        return readable
    }

    private static func readableIdentifier(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lastSegment = trimmed
            .split(separator: ":")
            .first
            .map(String.init) ?? trimmed
        let readable = readableLabel(lastSegment)
        return readable.isEmpty ? fallback : readable
    }

    static func readableLabel(_ value: String) -> String {
        splitCamelCase(value)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    static func safeTimestamp(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
    }

    private static func countLabel(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    private static func splitCamelCase(_ value: String) -> String {
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
}
