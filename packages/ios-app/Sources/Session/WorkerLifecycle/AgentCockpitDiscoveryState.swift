import Foundation

struct AgentCockpitCapabilityFamilyRow: Equatable, Identifiable, Sendable {
    var id: String
    var functionCount: Int
    var workerCount: Int
    var triggerCount: Int
    var degradedCount: Int
    var missingSchemaCount: Int
    var effectClasses: [String]
    var riskLevels: [String]
}

struct AgentCockpitDiscoveryReportRow: Equatable, Identifiable, Sendable {
    var id: String
    var resourceId: String
    var lifecycle: String
    var currentVersionId: String?
    var updatedAt: String?
}

struct AgentCockpitDiscoveryOverview: Equatable, Sendable {
    var title: String
    var detail: String
    var systemImage: String
    var functionCount: Int
    var workerCount: Int
    var triggerCount: Int
    var triggerTypeCount: Int
    var namespaceCount: Int
    var degradedFunctionCount: Int
    var missingSchemaCount: Int
    var latestReport: AgentCockpitDiscoveryReportRow?
    var reports: [AgentCockpitDiscoveryReportRow]
    var families: [AgentCockpitCapabilityFamilyRow]

    static let empty = AgentCockpitDiscoveryOverview(
        title: "No Catalog",
        detail: "No capability catalog is available",
        systemImage: "questionmark.folder",
        functionCount: 0,
        workerCount: 0,
        triggerCount: 0,
        triggerTypeCount: 0,
        namespaceCount: 0,
        degradedFunctionCount: 0,
        missingSchemaCount: 0,
        latestReport: nil,
        reports: [],
        families: []
    )
}

extension AgentCockpitProjection {
    static func discoveryOverview(
        workers: [AgentCockpitWorkerRow],
        functions: [AgentCockpitFunctionRow],
        triggers: [AgentCockpitTriggerRow],
        triggerTypes: [TriggerTypeCatalogDefinitionDTO],
        reports: [EngineResourceDTO]
    ) -> AgentCockpitDiscoveryOverview {
        let reportRows = reports.compactMap(discoveryReportRow)
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        let degraded = functions.filter { ["degraded", "unhealthy", "unknown"].contains(normalized($0.health)) }.count
        let missingSchemas = functions.filter { !$0.schemaComplete }.count
        let namespaceIds = Set(functions.map { namespace(for: $0.id) })
        let families = namespaceIds.map { namespace in
            capabilityFamily(namespace: namespace, workers: workers, functions: functions, triggers: triggers)
        }
        .sorted { lhs, rhs in
            if lhs.missingSchemaCount == rhs.missingSchemaCount {
                if lhs.degradedCount == rhs.degradedCount { return lhs.id < rhs.id }
                return lhs.degradedCount > rhs.degradedCount
            }
            return lhs.missingSchemaCount > rhs.missingSchemaCount
        }

        let latestReport = reportRows.first
        let normalizedLatest = latestReport.map { normalized($0.lifecycle) }
        let title: String
        let detail: String
        let image: String
        if missingSchemas > 0 {
            title = "Schema Gaps"
            detail = "\(missingSchemas) of \(functions.count) functions need schema evidence"
            image = "doc.badge.gearshape"
        } else if degraded > 0 {
            title = "Attention"
            detail = "\(degraded) functions are degraded, unhealthy, or unknown"
            image = "waveform.path.ecg"
        } else if normalizedLatest == "passed" {
            title = "Verified"
            detail = latestReport?.updatedAt ?? "Latest report passed"
            image = "checkmark.shield"
        } else if normalizedLatest == "failed" || normalizedLatest == "quarantined" {
            title = "Report Failed"
            detail = latestReport?.updatedAt ?? "Latest report needs review"
            image = "exclamationmark.shield"
        } else if functions.isEmpty && workers.isEmpty {
            title = "No Catalog"
            detail = "No capability catalog is available"
            image = "questionmark.folder"
        } else {
            title = "Unverified"
            detail = "\(functions.count) functions across \(namespaceIds.count) namespaces"
            image = "shield.lefthalf.filled"
        }

        return AgentCockpitDiscoveryOverview(
            title: title,
            detail: detail,
            systemImage: image,
            functionCount: functions.count,
            workerCount: workers.count,
            triggerCount: triggers.count,
            triggerTypeCount: triggerTypes.count,
            namespaceCount: namespaceIds.count,
            degradedFunctionCount: degraded,
            missingSchemaCount: missingSchemas,
            latestReport: latestReport,
            reports: reportRows,
            families: families
        )
    }

    private static func capabilityFamily(
        namespace namespaceId: String,
        workers: [AgentCockpitWorkerRow],
        functions: [AgentCockpitFunctionRow],
        triggers: [AgentCockpitTriggerRow]
    ) -> AgentCockpitCapabilityFamilyRow {
        let namespaceFunctions = functions.filter { namespace(for: $0.id) == namespaceId }
        let namespaceWorkers = workers.filter { worker in
            worker.id == namespaceId
                || worker.id.hasPrefix("\(namespaceId).")
                || worker.namespaceClaims.contains(namespaceId)
                || worker.namespaceClaims.contains { $0.hasPrefix("\(namespaceId).") }
        }
        let namespaceTriggers = triggers.filter { namespace(for: $0.targetFunction) == namespaceId }
        return AgentCockpitCapabilityFamilyRow(
            id: namespaceId,
            functionCount: namespaceFunctions.count,
            workerCount: namespaceWorkers.count,
            triggerCount: namespaceTriggers.count,
            degradedCount: namespaceFunctions.filter { ["degraded", "unhealthy", "unknown"].contains(normalized($0.health)) }.count,
            missingSchemaCount: namespaceFunctions.filter { !$0.schemaComplete }.count,
            effectClasses: Array(Set(namespaceFunctions.map { $0.effectClass })).sorted(),
            riskLevels: Array(Set(namespaceFunctions.map { $0.riskLevel })).sorted()
        )
    }

    private static func discoveryReportRow(_ resource: EngineResourceDTO) -> AgentCockpitDiscoveryReportRow? {
        guard resource.kind == WorkerLifecycleResourceKind.catalogDiscoveryReport.rawValue else { return nil }
        return AgentCockpitDiscoveryReportRow(
            id: resource.resourceId,
            resourceId: resource.resourceId,
            lifecycle: resource.lifecycle,
            currentVersionId: resource.currentVersionId,
            updatedAt: resource.updatedAt
        )
    }

    private static func namespace(for functionId: String) -> String {
        if let separator = functionId.range(of: "::") {
            return String(functionId[..<separator.lowerBound])
        }
        if let separator = functionId.firstIndex(of: ".") {
            return String(functionId[..<separator])
        }
        return functionId
    }
}
