import Foundation

struct EngineConsoleModuleOperatorProjection: Equatable {
    var packages: [EngineConsoleModuleResourceSummary]
    var configs: [EngineConsoleModuleResourceSummary]
    var activations: [EngineConsoleModuleResourceSummary]
    var health: [EngineConsoleModuleHealthSummary]
    var sourceTrust: [EngineConsoleModuleSourceTrustSummary]
    var actions: [EngineConsoleModuleActionSummary]

    var cardTitle: String { "Packs" }
    var cardSubtitle: String {
        "Local capability packs, trust, health, evidence, and server-authored controls."
    }
    var emptyTitle: String { "No packs" }
    var emptyMessage: String {
        "Registered packs and activation records will appear here after local pack capabilities run."
    }

    static let empty = EngineConsoleModuleOperatorProjection(
        packages: [],
        configs: [],
        activations: [],
        health: [],
        sourceTrust: [],
        actions: []
    )

    var isEmpty: Bool {
        packages.isEmpty
            && configs.isEmpty
            && activations.isEmpty
            && health.isEmpty
            && sourceTrust.isEmpty
            && actions.isEmpty
    }

    var evidenceRefCount: Int {
        var refs: [String] = []
        refs.append(contentsOf: health.flatMap(\.evidenceRefs))
        refs.append(contentsOf: sourceTrust.flatMap(\.evidenceRefs))
        return Array(Set(refs)).count
    }

    var surfaceTargets: [EngineConsoleModuleSurfaceTarget] {
        packages.map {
            EngineConsoleModuleSurfaceTarget(
                targetType: "package",
                targetId: $0.resourceId,
                title: "Pack Controls",
                subtitle: $0.displayName,
                symbol: "shippingbox"
            )
        } + activations.map {
            EngineConsoleModuleSurfaceTarget(
                targetType: "activation",
                targetId: $0.resourceId,
                title: "Activation Controls",
                subtitle: $0.displayName,
                symbol: "bolt.badge.clock"
            )
        }
    }

    static func make(from snapshot: ControlSnapshotDTO?) -> EngineConsoleModuleOperatorProjection {
        guard let snapshot else { return .empty }
        return EngineConsoleModuleOperatorProjection(
            packages: (snapshot.modulePackages ?? []).compactMap {
                EngineConsoleModuleResourceSummary($0, defaultKind: "worker_package")
            },
            configs: (snapshot.moduleConfigs ?? []).compactMap {
                EngineConsoleModuleResourceSummary($0, defaultKind: "module_config")
            },
            activations: (snapshot.activationRecords ?? []).compactMap {
                EngineConsoleModuleResourceSummary($0, defaultKind: "activation_record")
            },
            health: (snapshot.moduleHealth ?? []).compactMap(EngineConsoleModuleHealthSummary.init),
            sourceTrust: (snapshot.moduleSourceTrust ?? []).compactMap(EngineConsoleModuleSourceTrustSummary.init),
            actions: (snapshot.availableActions ?? [])
                .compactMap(EngineConsoleModuleActionSummary.init)
                .filter { $0.functionId.hasPrefix("module::") }
        )
    }
}

struct EngineConsoleModuleSurfaceTarget: Equatable, Identifiable {
    var targetType: String
    var targetId: String
    var title: String
    var subtitle: String
    var symbol: String

    var id: String { "\(targetType):\(targetId)" }
}

struct EngineConsoleModuleResourceSummary: Equatable, Identifiable {
    var resourceId: String
    var versionId: String?
    var kind: String
    var lifecycle: String?
    var scope: String?

    var id: String { resourceId }
    var displayName: String {
        resourceId
            .replacingOccurrences(of: "worker-package:", with: "")
            .replacingOccurrences(of: "module-config:", with: "")
            .replacingOccurrences(of: "activation:", with: "")
    }
    var lifecycleLabel: String {
        switch lifecycle {
        case "available":
            kind == "worker_package" ? "Registered" : "Available"
        case "active":
            kind == "module_config" ? "Configured" : "Activated"
        case "disabled":
            "Disabled"
        case "rolled_back":
            "Rolled back"
        case "quarantined":
            "Quarantined"
        case "discarded", "removed":
            "Removed"
        case "failed":
            "Failed"
        case let lifecycle?:
            lifecycle
        case nil:
            "Unknown"
        }
    }

    init?(_ value: AnyCodable, defaultKind: String) {
        guard let dictionary = value.dictionaryValue else { return nil }
        guard let resourceId = moduleString(dictionary, keys: ["resourceId", "resource_id", "id"]) else {
            return nil
        }
        self.resourceId = resourceId
        self.versionId = moduleString(
            dictionary,
            keys: ["currentVersionId", "current_version_id", "versionId", "version_id"]
        )
        self.kind = moduleString(dictionary, keys: ["kind", "resourceKind"]) ?? defaultKind
        self.lifecycle = moduleString(dictionary, keys: ["lifecycle", "state", "status"])
        self.scope = moduleString(dictionary, keys: ["scope", "scopeId", "workspaceId", "sessionId"])
    }
}

struct EngineConsoleModuleHealthSummary: Equatable, Identifiable {
    var activationResourceId: String
    var activationVersionId: String?
    var activationStatus: String?
    var workerId: String?
    var healthSummary: String?
    var healthEvidenceRef: String?
    var integritySummary: String?
    var recoverySummary: String?

    var id: String { activationResourceId }
    var evidenceRefs: [String] { [healthEvidenceRef].compactMap { $0 } }

    init?(_ value: AnyCodable) {
        guard let dictionary = value.dictionaryValue else { return nil }
        guard let activationResourceId = moduleString(dictionary, keys: ["activationResourceId", "resourceId"]) else {
            return nil
        }
        self.activationResourceId = activationResourceId
        self.activationVersionId = moduleString(dictionary, keys: ["activationVersionId", "versionId"])
        self.activationStatus = moduleString(dictionary, keys: ["activationStatus", "status"])
        self.workerId = moduleString(dictionary, keys: ["workerId"])
        self.healthSummary = moduleNestedSummary(dictionary["healthResult"])
        self.healthEvidenceRef = moduleReferenceId(dictionary["healthEvidenceRef"])
        self.integritySummary = moduleNestedSummary(dictionary["integrityDiagnostics"])
        self.recoverySummary = moduleNestedSummary(dictionary["recovery"])
    }
}

struct EngineConsoleModuleSourceTrustSummary: Equatable, Identifiable {
    var packageResourceId: String
    var packageVersionId: String?
    var packageId: String?
    var presentation: EngineConsoleModuleTrustPresentation
    var sourceTrustStatus: String?
    var effectiveTrustTier: String?
    var signatureStatus: String?
    var sourceEvidenceRefs: [String]
    var sourceRegistrationRefs: [String]
    var trustRootRefs: [String]
    var sourceApprovalRefs: [String]
    var approvalWarningCodes: [String]
    var trustWarningCodes: [String]
    var conformanceEvidenceRefs: [String]
    var policyDiagnosticKeys: [String]

    var id: String { packageResourceId }

    var evidenceRefs: [String] {
        sourceEvidenceRefs
            + sourceRegistrationRefs
            + trustRootRefs
            + sourceApprovalRefs
            + conformanceEvidenceRefs
    }

    init?(_ value: AnyCodable) {
        guard let dictionary = value.dictionaryValue else { return nil }
        guard let packageResourceId = moduleString(dictionary, keys: ["packageResourceId", "resourceId"]) else {
            return nil
        }
        guard let presentation = EngineConsoleModuleTrustPresentation(dictionary["trustPresentation"]) else {
            return nil
        }
        self.packageResourceId = packageResourceId
        self.presentation = presentation
        self.packageVersionId = moduleString(dictionary, keys: ["packageVersionId", "versionId"])
        self.packageId = moduleString(dictionary, keys: ["packageId"])
        self.sourceTrustStatus = moduleString(dictionary, keys: ["sourceTrustStatus", "status"])
        self.effectiveTrustTier = moduleString(dictionary, keys: ["effectiveTrustTier", "trustTier"])
        self.signatureStatus = moduleNestedSummary(dictionary["signatureVerification"])
        self.sourceEvidenceRefs = moduleReferenceIds(dictionary["sourceEvidenceRefs"])
        self.sourceRegistrationRefs = moduleReferenceIds(dictionary["sourceRegistrationRefs"])
        self.trustRootRefs = moduleReferenceIds(dictionary["trustRootRefs"])
        self.sourceApprovalRefs = moduleReferenceIds(dictionary["sourceApprovalRefs"])
        self.approvalWarningCodes = moduleWarningCodes(dictionary["approvalWarnings"])
        self.trustWarningCodes = moduleWarningCodes(dictionary["trustWarnings"])
        self.conformanceEvidenceRefs = moduleReferenceIds(dictionary["conformanceEvidenceRefs"])
        self.policyDiagnosticKeys = (dictionary["policyDiagnostics"] as? [String: Any])?
            .keys
            .sorted() ?? []
    }
}

struct EngineConsoleModuleTrustPresentation: Equatable {
    var statusLabel: String
    var statusTone: String
    var summary: String
    var sourceLabel: String
    var signatureLabel: String
    var approvalLabel: String
    var conformanceLabel: String
    var revocationLabel: String
    var promotionLabel: String
    var cleanupLabel: String
    var evidenceLabels: [String]
    var warningLabels: [String]

    init?(_ value: Any?) {
        guard let dictionary = value as? [String: Any],
              let statusLabel = moduleString(dictionary, keys: ["statusLabel"]),
              let statusTone = moduleString(dictionary, keys: ["statusTone"]),
              let summary = moduleString(dictionary, keys: ["summary"]),
              let sourceLabel = moduleString(dictionary, keys: ["sourceLabel"]),
              let signatureLabel = moduleString(dictionary, keys: ["signatureLabel"]),
              let approvalLabel = moduleString(dictionary, keys: ["approvalLabel"]),
              let conformanceLabel = moduleString(dictionary, keys: ["conformanceLabel"]),
              let revocationLabel = moduleString(dictionary, keys: ["revocationLabel"]),
              let promotionLabel = moduleString(dictionary, keys: ["promotionLabel"]),
              let cleanupLabel = moduleString(dictionary, keys: ["cleanupLabel"])
        else {
            return nil
        }
        self.statusLabel = statusLabel
        self.statusTone = statusTone
        self.summary = summary
        self.sourceLabel = sourceLabel
        self.signatureLabel = signatureLabel
        self.approvalLabel = approvalLabel
        self.conformanceLabel = conformanceLabel
        self.revocationLabel = revocationLabel
        self.promotionLabel = promotionLabel
        self.cleanupLabel = cleanupLabel
        self.evidenceLabels = moduleStringArray(dictionary["evidenceLabels"])
        self.warningLabels = moduleStringArray(dictionary["warningLabels"])
    }
}

struct EngineConsoleModuleActionSummary: Equatable, Identifiable {
    var functionId: String
    var label: String?
    var targetType: String?
    var targetField: String?
    var targetValue: String?
    var requiredRisk: String?
    var approvalRequired: Bool
    var state: String?
    var presentationIcon: String?

    var id: String {
        [
            functionId,
            label,
            targetType,
            targetField,
            targetValue
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    var displayLabel: String { label ?? functionId }

    var detailText: String {
        [
            targetType,
            targetField,
            requiredRisk,
            approvalRequired ? "approval" : nil,
            state
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " / ")
    }

    init?(_ value: AnyCodable) {
        guard let dictionary = value.dictionaryValue else { return nil }
        guard let functionId = moduleString(dictionary, keys: ["functionId", "targetFunctionId"]) else {
            return nil
        }
        self.functionId = functionId
        self.label = moduleString(dictionary, keys: ["label"])
        self.targetType = moduleString(dictionary, keys: ["targetType"])
        let target = dictionary["target"] as? [String: Any]
        self.targetField = moduleString(dictionary, keys: ["targetField"]) ?? moduleString(target, keys: ["field"])
        self.targetValue = moduleDisplayString(target?["value"]) ?? moduleDisplayString(dictionary["target"])
        self.requiredRisk = moduleString(dictionary, keys: ["requiredRisk", "risk"])
        self.approvalRequired = moduleBool(dictionary, keys: ["approvalRequired"]) ?? false
        self.state = moduleString(dictionary, keys: ["state"])
        self.presentationIcon = moduleString(dictionary["presentation"] as? [String: Any], keys: ["icon"])
    }
}

private func moduleString(_ dictionary: [String: Any]?, keys: [String]) -> String? {
    guard let dictionary else { return nil }
    for key in keys {
        if let string = dictionary[key] as? String, !string.isEmpty {
            return string
        }
        if let int = dictionary[key] as? Int {
            return String(int)
        }
        if let double = dictionary[key] as? Double {
            return String(double)
        }
        if let bool = dictionary[key] as? Bool {
            return bool ? "true" : "false"
        }
    }
    return nil
}

private func moduleBool(_ dictionary: [String: Any]?, keys: [String]) -> Bool? {
    guard let dictionary else { return nil }
    for key in keys {
        if let bool = dictionary[key] as? Bool {
            return bool
        }
    }
    return nil
}

private func moduleReferenceIds(_ value: Any?) -> [String] {
    if let array = value as? [Any] {
        return array.compactMap(moduleReferenceId)
    }
    return [moduleReferenceId(value)].compactMap { $0 }
}

private func moduleReferenceId(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty {
        return string
    }
    guard let dictionary = value as? [String: Any] else { return nil }
    return moduleString(
        dictionary,
        keys: [
            "resourceId",
            "evidenceResourceId",
            "decisionResourceId",
            "trustDecisionResourceId",
            "id"
        ]
    )
}

private func moduleWarningCodes(_ value: Any?) -> [String] {
    guard let array = value as? [Any] else { return [] }
    return array.compactMap { item in
        guard let dictionary = item as? [String: Any] else { return nil }
        return moduleString(dictionary, keys: ["code", "message"])
    }
}

private func moduleStringArray(_ value: Any?) -> [String] {
    guard let array = value as? [Any] else { return [] }
    return array.compactMap(moduleDisplayString)
}

private func moduleNestedSummary(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty {
        return string
    }
    guard let dictionary = value as? [String: Any] else {
        return moduleDisplayString(value)
    }
    return moduleString(
        dictionary,
        keys: [
            "status",
            "state",
            "outcome",
            "summary",
            "message",
            "recoveryStatus",
            "integrityStatus",
            "evidenceRef"
        ]
    )
}

private func moduleDisplayString(_ value: Any?) -> String? {
    switch value {
    case let string as String where !string.isEmpty:
        string
    case let int as Int:
        String(int)
    case let double as Double:
        String(double)
    case let bool as Bool:
        bool ? "true" : "false"
    default:
        nil
    }
}
