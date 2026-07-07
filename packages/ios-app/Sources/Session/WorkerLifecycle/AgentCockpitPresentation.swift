import Foundation

enum AgentCockpitPresentation {
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

    static func verificationTitle(for overview: AgentCockpitDiscoveryOverview) -> String {
        switch overview.title {
        case "Verified":
            return "Capabilities verified"
        case "No Catalog", "No Capabilities":
            return "No capabilities published"
        case "Catalog Degraded", "Capabilities Need Review":
            return "Capabilities need review"
        case "Report Failed":
            return "Verification needs review"
        default:
            return overview.title
        }
    }

    static func verificationDetail(for overview: AgentCockpitDiscoveryOverview) -> String {
        if overview.functionCount == 0, overview.operationCount == 0 {
            return overview.detail.replacingOccurrences(of: "capability catalog", with: "capabilities")
                .replacingOccurrences(of: "catalog", with: "capability map")
        }
        if let operationList = overview.capabilityVisibility?.operationList, operationList.truncated {
            return "\(operationList.returnedOperations) of \(operationList.totalOperations) operations are visible. Open details for the bounded verification result."
        }
        if let resourceScan = overview.capabilityVisibility?.resourceScan, resourceScan.truncated {
            return "\(overview.operationCount) operations are visible. Some supporting evidence was bounded."
        }
        if overview.degradedFunctionCount + overview.missingSchemaCount + overview.catalogDecodeIssueCount > 0 {
            return overview.detail.replacingOccurrences(of: "catalog", with: "capability map")
        }
        let visibleOperations = overview.operationCount > 0 ? overview.operationCount : overview.functionCount
        return "\(visibleOperations) operations are visible across \(overview.groups.count) capability areas."
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
            return "Runtime-routable"
        case "producerextensible":
            return "Producer-extensible"
        case "kernelevolutiononly":
            return "Kernel-evolution only"
        default:
            return displayLabel(value)
        }
    }

    static func capabilityVisibilityLabel(_ value: String) -> String {
        switch AgentCockpitProjection.normalized(value) {
        case "defaultvisible":
            return "Default-visible"
        case "searchvisible":
            return "Search-visible"
        case "inspectonly":
            return "Inspect-only"
        case "hiddenunlessevolutionmode":
            return "Evolution-only"
        default:
            return displayLabel(value)
        }
    }

    static func capabilityMinimalityLabel(_ value: String) -> String {
        switch AgentCockpitProjection.normalized(value) {
        case "keepcore":
            return "Keep core"
        case "keepgovernance":
            return "Keep governance"
        case "modulecandidate":
            return "Module candidate"
        default:
            return displayLabel(value)
        }
    }

    static func safeLastChecked(_ report: AgentCockpitDiscoveryReportRow?) -> String? {
        guard let report else { return nil }
        return safeTimestamp(report.updatedAt) ?? verificationStatus(for: report).lowercased()
    }

    static func groupMetricTitle(for group: AgentCockpitCapabilityGroupRow, metric: CapabilityGroupMetric) -> String {
        switch metric {
        case .operations:
            return "Operations"
        case .definitions:
            return group.operationCount > 0 ? "Contracts" : "Functions"
        case .workers:
            return "Workers"
        case .issues:
            return "Issues"
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
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
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
}

enum CapabilityGroupMetric {
    case operations
    case definitions
    case workers
    case issues
}
