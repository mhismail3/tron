import Foundation

struct AgentCockpitDashboardCount: Equatable, Sendable {
    var value: Int?
    var isComplete: Bool

    var displayValue: String {
        guard let value else { return "—" }
        return isComplete ? "\(value)" : "\(value)+"
    }

    func phrase(singular: String, plural: String) -> String {
        guard value != nil else {
            return plural.prefix(1).uppercased() + String(plural.dropFirst()) + " unavailable"
        }
        let label = value == 1 && isComplete ? singular : plural
        return "\(displayValue) \(label)"
    }
}

struct AgentCockpitDashboardSummary: Equatable, Sendable {
    var statusKind: AgentCockpitStatusKind
    var title: String
    var detail: String
    var systemImage: String
    var agentActions: AgentCockpitDashboardCount
    var workers: Int
    var triggers: Int
    var verification: String
    var engineActions: AgentCockpitDashboardCount
    var engineInterfaces: Int
    var recentActivityTitle: String
    var activeActivity: Int
    var waitingActivity: Int
    var blockedActivity: Int
    var degradedActivity: Int
    var issues: Int
}

enum AgentCockpitPresentation {
    static func countPhrase(_ count: Int, singular: String, plural: String) -> String {
        AgentCockpitDashboardCount(value: count, isComplete: true)
            .phrase(singular: singular, plural: plural)
    }

    static func dashboardSummary(for overview: AgentCockpitOverview) -> AgentCockpitDashboardSummary {
        let hasOperationProjection = overview.capabilityVisibility != nil
        let operationProjectionIsComplete = overview.capabilityVisibility.map {
            $0.operationList.complete && !$0.operationList.truncated
        } ?? false
        let active = overview.moduleActivity?.summary.active
            ?? overview.activity.filter { normalizedActivityState($0.status) == "active" }.count
        let waiting = overview.moduleActivity?.summary.waiting
            ?? overview.activity.filter { normalizedActivityState($0.status) == "waiting" }.count
        let blocked = overview.moduleActivity?.summary.blocked
            ?? overview.activity.filter { normalizedActivityState($0.status) == "blocked" }.count
        let degraded = overview.moduleActivity?.summary.degraded
            ?? overview.activity.filter { normalizedActivityState($0.status) == "degraded" }.count
        let issues = overview.issueCount

        let status: AgentCockpitStatusSummary
        if [.offline, .connecting, .degraded].contains(overview.status.kind) {
            status = overview.status
        } else if issues > 0 {
            status = .init(
                kind: .degraded,
                title: "Needs Review",
                detail: overview.issueDetail,
                systemImage: "exclamationmark.triangle"
            )
        } else if waiting > 0 || overview.status.kind == .awaitingApproval {
            status = .init(
                kind: .awaitingApproval,
                title: "Needs You",
                detail: waiting > 0
                    ? activityDetail(
                        overview.moduleActivity?.summary.detail,
                        fallback: "\(waiting) item\(waiting == 1 ? " is" : "s are") waiting for you."
                    )
                    : overview.status.detail,
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } else if active > 0 {
            status = .init(
                kind: .running,
                title: "Active",
                detail: activityDetail(
                    overview.moduleActivity?.summary.detail,
                    fallback: "\(active) recent work item\(active == 1 ? " is" : "s are") active."
                ),
                systemImage: "waveform.path.ecg"
            )
        } else {
            status = .init(
                kind: overview.status.kind,
                title: overview.status.kind == .idle ? "All Systems Quiet" : overview.status.title,
                detail: dashboardIdleDetail(for: overview.status.kind),
                systemImage: overview.status.systemImage
            )
        }

        let recentActivityTitle: String
        if blocked > 0 || degraded > 0 {
            recentActivityTitle = "Needs review"
        } else if waiting > 0 {
            recentActivityTitle = "Needs you"
        } else if active > 0 {
            recentActivityTitle = "Active"
        } else {
            recentActivityTitle = "No recent work"
        }

        return AgentCockpitDashboardSummary(
            statusKind: status.kind,
            title: status.title,
            detail: status.detail,
            systemImage: status.systemImage,
            agentActions: .init(
                value: hasOperationProjection ? overview.discovery.agentOperationCount : nil,
                isComplete: operationProjectionIsComplete
            ),
            workers: overview.workers.count,
            triggers: overview.triggers.count,
            verification: verificationPhrase(for: overview.discovery.latestReport),
            engineActions: .init(
                value: hasOperationProjection ? overview.discovery.engineOperationCount : nil,
                isComplete: operationProjectionIsComplete
            ),
            engineInterfaces: overview.functions.count,
            recentActivityTitle: recentActivityTitle,
            activeActivity: active,
            waitingActivity: waiting,
            blockedActivity: blocked,
            degradedActivity: degraded,
            issues: issues
        )
    }

    static func verificationStatus(for report: AgentCockpitDiscoveryReportRow?) -> String {
        guard let report else { return "Unchecked" }
        switch AgentCockpitProjection.normalized(report.lifecycle) {
        case "passed":
            return "Passed"
        case "failed", "quarantined":
            return "Needs Review"
        default:
            return displayLabel(report.lifecycle)
        }
    }

    static func verificationPhrase(for report: AgentCockpitDiscoveryReportRow?) -> String {
        switch verificationStatus(for: report) {
        case "Passed":
            return "Verified"
        case "Needs Review":
            return "Review needed"
        case "Unchecked":
            return "Not checked yet"
        case let status:
            return "Check \(status.lowercased())"
        }
    }

    static func verificationDetail(for overview: AgentCockpitDiscoveryOverview) -> String {
        guard overview.capabilityVisibility != nil else {
            guard overview.functionCount > 0 else {
                return "Agent action inventory is unavailable."
            }
            let interfacePhrase = overview.functionCount == 1
                ? "1 engine interface remains"
                : "\(overview.functionCount) engine interfaces remain"
            return "Agent action inventory is unavailable. \(interfacePhrase) visible for diagnostics."
        }
        if overview.functionCount == 0, overview.operationCount == 0 {
            return overview.detail.replacingOccurrences(of: "capability catalog", with: "capabilities")
                .replacingOccurrences(of: "catalog", with: "capability map")
        }
        if let operationList = overview.capabilityVisibility?.operationList, operationList.truncated {
            return "\(overview.agentOperationCount)+ agent actions are visible. Open details for the bounded verification result."
        }
        if let resourceScan = overview.capabilityVisibility?.resourceScan, resourceScan.truncated {
            return "\(overview.agentOperationCount) agent actions are visible. Some supporting evidence was bounded."
        }
        if overview.degradedFunctionCount + overview.missingSchemaCount + overview.catalogDecodeIssueCount > 0 {
            return overview.detail.replacingOccurrences(of: "catalog", with: "capability map")
        }
        return "\(overview.agentOperationCount) agent actions are available."
    }

    static func capabilityAudienceLabel(_ value: String) -> String {
        switch AgentCockpitProjection.normalized(value) {
        case "sessionwork":
            return "Session work"
        case "agentdiagnostics":
            return "Agent diagnostics"
        case "governance":
            return "Governance"
        case "engineinternal":
            return "Engine internal"
        case "kernelevolution":
            return "Kernel evolution"
        default:
            return displayLabel(value)
        }
    }

    static func capabilityReplacementClassLabel(_ value: String) -> String {
        switch AgentCockpitProjection.normalized(value) {
        case "runtimeroutable":
            return "Can be replaced safely"
        case "producerextensible":
            return "Can be extended"
        case "kernelevolutiononly":
            return "Engine update only"
        default:
            return displayLabel(value)
        }
    }

    static func capabilityVisibilityLabel(_ value: String) -> String {
        switch AgentCockpitProjection.normalized(value) {
        case "defaultvisible":
            return "Visible to the agent"
        case "searchvisible":
            return "Available by search"
        case "inspectonly":
            return "Details only"
        case "hiddenunlessevolutionmode":
            return "Developer-only"
        default:
            return displayLabel(value)
        }
    }

    static func capabilityMinimalityLabel(_ value: String) -> String {
        switch AgentCockpitProjection.normalized(value) {
        case "keepcore":
            return "Stays in the engine"
        case "keepgovernance":
            return "Stays engine-owned"
        case "modulecandidate":
            return "Can become a module"
        default:
            return displayLabel(value)
        }
    }

    static func workKindLabel(_ rawKind: String) -> String {
        switch AgentCockpitProjection.normalized(rawKind) {
        case "moduleruntimestate":
            return "Runtime"
        case "modulelifecyclestate":
            return "Lifecycle"
        case "moduledependencyrequest":
            return "Dependency request"
        case "moduledependencydecision":
            return "Dependency decision"
        case "moduledependencypolicy":
            return "Dependency policy"
        case "modulevalidationrecord":
            return "Validation"
        case "moduleinstallrecord":
            return "Install"
        case "moduleauthoringrecord":
            return "Authoring"
        default:
            return displayLabel(rawKind)
        }
    }

    static func workStateLine(kind: String, status: String) -> String {
        "\(workKindLabel(kind)) · \(displayLabel(status))"
    }

    static func hiddenTopLevelTerms(in values: [String]) -> [String] {
        let forbidden = [
            "catalog",
            "capability map version",
            "audit detail",
            "resourceid",
            "resource id",
            "grant id",
            "authority id",
            "namespace claims",
            "rev "
        ]
        let joined = values.joined(separator: "\n").lowercased()
        return forbidden.filter { joined.contains($0) }
    }

    static func displayLabel(_ value: String) -> String {
        splitCamelCase(value)
            .replacingOccurrences(of: "::", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    static func functionDisplayName(_ value: String) -> String {
        let components = value.components(separatedBy: "::")
        guard components.count > 1, let namespace = components.first else {
            return displayLabel(value)
        }
        let action = components.dropFirst().joined(separator: " ")
        return "\(displayLabel(action)) \(displayLabel(namespace))"
    }

    static func provenanceLabel(_ value: String) -> String {
        let key = AgentCockpitProjection.normalized(value)
            .filter { $0.isLetter || $0.isNumber }
        switch key {
        case "capabilityexecuteregistry":
            return "Capability registry"
        case "capabilitybindingcockpitprojection":
            return "Dashboard projection"
        default:
            return displayLabel(value)
        }
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

    static func safeTimestamp(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
    }

    private static func normalizedActivityState(_ value: String) -> String {
        let normalized = AgentCockpitProjection.normalized(value)
        if ["running", "started", "inprogress"].contains(normalized) { return "active" }
        if ["pending", "awaiting", "approvalrequired"].contains(normalized) { return "waiting" }
        if ["failed", "quarantined"].contains(normalized) { return "degraded" }
        return normalized
    }

    private static func activityDetail(_ detail: String?, fallback: String) -> String {
        guard let detail, !detail.isEmpty else { return fallback }
        return detail
    }

    private static func dashboardIdleDetail(for status: AgentCockpitStatusKind) -> String {
        switch status {
        case .connecting:
            return "Rebuilding the engine link."
        case .degraded:
            return "Open Dashboard sections for safe diagnostics and evidence."
        case .awaitingApproval:
            return "A server-owned item is waiting for your review."
        case .running:
            return "Engine or module work is currently active."
        case .ready:
            return "Core link is healthy and capabilities are available."
        case .idle:
            return "No engine or module work is currently active."
        case .offline:
            return "Connect a server to inspect core health."
        }
    }
}
