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

struct AgentCockpitCapabilityGroupRow: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var question: String
    var narrative: String
    var ownerSummary: String
    var operationCount: Int
    var functionCount: Int
    var workerCount: Int
    var triggerCount: Int
    var degradedCount: Int
    var missingSchemaCount: Int
    var namespaces: [String]
    var families: [String]
    var operations: [AgentCockpitOperationRow]
    var functions: [AgentCockpitFunctionRow]
    var workerIds: [String]
    var triggerIds: [String]

    var hasIssues: Bool {
        degradedCount > 0 || missingSchemaCount > 0
    }

    var workerTriggerExplanation: String? {
        guard operationCount > 0 || functionCount > 0, workerCount == 0, triggerCount == 0 else { return nil }
        if operationCount > 0 {
            return "These actions are engine-owned. Worker and trigger counts appear when a module publishes autonomous runtime owners."
        }
        return "These interfaces are built into the engine and do not require an autonomous module worker."
    }
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
    var operationCount: Int
    var workerCount: Int
    var triggerCount: Int
    var triggerTypeCount: Int
    var namespaceCount: Int
    var degradedFunctionCount: Int
    var missingSchemaCount: Int
    var catalogDecodeIssueCount: Int
    var latestReport: AgentCockpitDiscoveryReportRow?
    var reports: [AgentCockpitDiscoveryReportRow]
    var families: [AgentCockpitCapabilityFamilyRow]
    var groups: [AgentCockpitCapabilityGroupRow]
    var engineGroups: [AgentCockpitCapabilityGroupRow]
    var agentOperationCount: Int
    var engineOperationCount: Int
    var engineFunctionCount: Int
    var capabilityVisibility: CapabilityCockpitOverviewDTO?

    static let empty = AgentCockpitDiscoveryOverview(
        title: "No Operations",
        detail: "No operations are available",
        systemImage: "questionmark.folder",
        functionCount: 0,
        operationCount: 0,
        workerCount: 0,
        triggerCount: 0,
        triggerTypeCount: 0,
        namespaceCount: 0,
        degradedFunctionCount: 0,
        missingSchemaCount: 0,
        catalogDecodeIssueCount: 0,
        latestReport: nil,
        reports: [],
        families: [],
        groups: [],
        engineGroups: [],
        agentOperationCount: 0,
        engineOperationCount: 0,
        engineFunctionCount: 0,
        capabilityVisibility: nil
    )
}

extension AgentCockpitProjection {
    static func discoveryOverview(
        workers: [AgentCockpitWorkerRow],
        functions: [AgentCockpitFunctionRow],
        triggers: [AgentCockpitTriggerRow],
        triggerTypes: [TriggerTypeCatalogDefinitionDTO],
        catalogDecodeIssues: [CatalogDefinitionDecodeIssue],
        reports: [EngineResourceDTO],
        modularityOperations: [AgentCockpitOperationRow] = [],
        capabilityVisibility: CapabilityCockpitOverviewDTO? = nil
    ) -> AgentCockpitDiscoveryOverview {
        let reportRows = reports.compactMap(discoveryReportRow)
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        // A present cockpit projection is authoritative even when it contains
        // zero operations. Falling back to catalog interfaces in that state
        // would turn a truthful empty action set into a misleading capability
        // inventory.
        let hasOperationProjection = capabilityVisibility != nil
        let degraded = functions.filter { ["degraded", "unhealthy", "unknown"].contains(normalized($0.health)) }.count
        let missingSchemas = functions.filter { !$0.schemaComplete }.count
        let topLevelDegraded = hasOperationProjection ? 0 : degraded
        let topLevelMissingSchemas = hasOperationProjection ? 0 : missingSchemas
        let topLevelCatalogDecodeIssues = hasOperationProjection ? 0 : catalogDecodeIssues.count
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
        let agentOperations = modularityOperations.filter(\.isAgentFunctionalCapability)
        let engineOperations = modularityOperations.filter { !$0.isAgentFunctionalCapability }
        let groups: [AgentCockpitCapabilityGroupRow]
        let engineGroups: [AgentCockpitCapabilityGroupRow]
        if hasOperationProjection {
            groups = capabilityGroups(
                workers: workers,
                functions: [],
                modularityOperations: agentOperations,
                triggers: [],
                hasOperationProjection: true,
                includesLockedOwnership: false
            )
            engineGroups = capabilityGroups(
                workers: workers,
                functions: functions,
                modularityOperations: engineOperations,
                triggers: triggers,
                hasOperationProjection: true,
                includesLockedOwnership: true
            )
        } else {
            groups = []
            engineGroups = capabilityGroups(
                workers: workers,
                functions: functions,
                modularityOperations: [],
                triggers: triggers,
                hasOperationProjection: false,
                includesLockedOwnership: true
            )
        }

        let latestReport = reportRows.first
        let normalizedLatest = latestReport.map { normalized($0.lifecycle) }
        let title: String
        let detail: String
        let image: String
        if topLevelCatalogDecodeIssues > 0 {
            title = "Operations Need Review"
            detail = catalogDecodeIssueDetail(topLevelCatalogDecodeIssues)
            image = "exclamationmark.triangle"
        } else if topLevelMissingSchemas > 0 {
            title = "Schema Gaps"
            detail = "\(topLevelMissingSchemas) of \(functions.count) catalog definitions need schema evidence"
            image = "doc.badge.gearshape"
        } else if topLevelDegraded > 0 {
            title = "Attention"
            detail = "\(topLevelDegraded) catalog definitions are degraded, unhealthy, or unknown"
            image = "waveform.path.ecg"
        } else if normalizedLatest == "passed" {
            title = "Verified"
            detail = latestReport?.updatedAt ?? "Latest report passed"
            image = "checkmark.shield"
        } else if normalizedLatest == "failed" || normalizedLatest == "quarantined" {
            title = "Verification Needs Review"
            detail = latestReport?.updatedAt ?? "Latest report needs review"
            image = "exclamationmark.shield"
        } else if functions.isEmpty && workers.isEmpty && modularityOperations.isEmpty {
            title = hasOperationProjection ? "No Actions" : "No Engine Interfaces"
            detail = hasOperationProjection
                ? "No agent actions are available"
                : "No engine interfaces are available, and the agent action inventory is unavailable"
            image = "questionmark.folder"
        } else {
            title = "Unverified"
            if hasOperationProjection {
                detail = "\(agentOperations.count) agent actions across \(groups.count) capability areas"
            } else {
                let interfacePhrase = functions.count == 1
                    ? "1 engine interface remains"
                    : "\(functions.count) engine interfaces remain"
                detail = "Agent action inventory unavailable; \(interfacePhrase) inspectable"
            }
            image = "shield.lefthalf.filled"
        }

        return AgentCockpitDiscoveryOverview(
            title: title,
            detail: detail,
            systemImage: image,
            functionCount: functions.count,
            operationCount: modularityOperations.count,
            workerCount: workers.count,
            triggerCount: triggers.count,
            triggerTypeCount: triggerTypes.count,
            namespaceCount: namespaceIds.count,
            degradedFunctionCount: topLevelDegraded,
            missingSchemaCount: topLevelMissingSchemas,
            catalogDecodeIssueCount: topLevelCatalogDecodeIssues,
            latestReport: latestReport,
            reports: reportRows,
            families: families,
            groups: groups,
            engineGroups: engineGroups,
            agentOperationCount: hasOperationProjection ? agentOperations.count : 0,
            engineOperationCount: hasOperationProjection ? engineOperations.count : 0,
            engineFunctionCount: functions.count,
            capabilityVisibility: capabilityVisibility
        )
    }

    private static func capabilityGroups(
        workers: [AgentCockpitWorkerRow],
        functions: [AgentCockpitFunctionRow],
        modularityOperations: [AgentCockpitOperationRow],
        triggers: [AgentCockpitTriggerRow],
        hasOperationProjection: Bool,
        includesLockedOwnership: Bool
    ) -> [AgentCockpitCapabilityGroupRow] {
        var claimedNamespaces = Set<String>()
        var claimedFamilies = Set<String>()
        var groups: [AgentCockpitCapabilityGroupRow] = capabilityGroupDefinitions().compactMap { definition in
            let groupFunctions = functions.filter { definition.namespaces.contains(namespace(for: $0.id)) }
            let namespaceSet = Set(groupFunctions.map { namespace(for: $0.id) })
            claimedNamespaces.formUnion(namespaceSet)
            let groupOperations = modularityOperations.filter { definition.operationFamilies.contains($0.family) }
            let showsOperationProjection = hasOperationProjection || !groupOperations.isEmpty
            let familySet = Set(groupOperations.map(\.family))
            claimedFamilies.formUnion(familySet)
            let groupWorkers = workers.filter { worker in
                namespaceSet.contains(worker.id)
                    || worker.namespaceClaims.contains { namespaceSet.contains($0) }
                    || groupFunctions.contains { $0.ownerWorker == worker.id }
            }
            let groupTriggers = triggers.filter { trigger in
                definition.namespaces.contains(namespace(for: trigger.targetFunction))
            }
            guard !groupFunctions.isEmpty || !groupOperations.isEmpty || !groupWorkers.isEmpty || !groupTriggers.isEmpty else {
                return nil
            }
            return AgentCockpitCapabilityGroupRow(
                id: definition.id,
                title: definition.title,
                question: definition.question,
                narrative: definition.narrative,
                ownerSummary: ownerSummary(
                    workers: groupWorkers,
                    functions: groupFunctions,
                    operations: groupOperations,
                    includesLockedOwnership: includesLockedOwnership
                ),
                operationCount: groupOperations.count,
                functionCount: groupFunctions.count,
                workerCount: groupWorkers.count,
                triggerCount: groupTriggers.count,
                degradedCount: showsOperationProjection ? 0 : groupFunctions.filter { ["degraded", "unhealthy", "unknown"].contains(normalized($0.health)) }.count,
                missingSchemaCount: showsOperationProjection ? 0 : groupFunctions.filter { !$0.schemaComplete }.count,
                namespaces: Array(namespaceSet).sorted(),
                families: Array(familySet).sorted(),
                operations: groupOperations.sorted { $0.name < $1.name },
                functions: groupFunctions.sorted { $0.id < $1.id },
                workerIds: groupWorkers.map(\.id).sorted(),
                triggerIds: groupTriggers.map(\.id).sorted()
            )
        }
        let otherFunctions = functions.filter { !claimedNamespaces.contains(namespace(for: $0.id)) }
        let otherOperations = modularityOperations.filter { !claimedFamilies.contains($0.family) }
        if !otherFunctions.isEmpty || !otherOperations.isEmpty {
            let otherNamespaces = Set(otherFunctions.map { namespace(for: $0.id) })
            let otherFamilies = Set(otherOperations.map(\.family))
            let showsOperationProjection = hasOperationProjection || !otherOperations.isEmpty
            let otherWorkers = workers.filter { worker in
                otherNamespaces.contains(worker.id)
                    || worker.namespaceClaims.contains { otherNamespaces.contains($0) }
                    || otherFunctions.contains { $0.ownerWorker == worker.id }
            }
            let otherTriggers = triggers.filter { otherNamespaces.contains(namespace(for: $0.targetFunction)) }
            groups.append(
                AgentCockpitCapabilityGroupRow(
                    id: "other_capabilities",
                    title: "Other Capabilities",
                    question: "What else has Tron learned or exposed?",
                    narrative: "Additional namespaces, including future agent-authored capabilities that do not fit the built-in groups yet.",
                    ownerSummary: ownerSummary(
                        workers: otherWorkers,
                        functions: otherFunctions,
                        operations: otherOperations,
                        includesLockedOwnership: includesLockedOwnership
                    ),
                    operationCount: otherOperations.count,
                    functionCount: otherFunctions.count,
                    workerCount: otherWorkers.count,
                    triggerCount: otherTriggers.count,
                    degradedCount: showsOperationProjection ? 0 : otherFunctions.filter { ["degraded", "unhealthy", "unknown"].contains(normalized($0.health)) }.count,
                    missingSchemaCount: showsOperationProjection ? 0 : otherFunctions.filter { !$0.schemaComplete }.count,
                    namespaces: Array(otherNamespaces).sorted(),
                    families: Array(otherFamilies).sorted(),
                    operations: otherOperations.sorted { $0.name < $1.name },
                    functions: otherFunctions.sorted { $0.id < $1.id },
                    workerIds: otherWorkers.map(\.id).sorted(),
                    triggerIds: otherTriggers.map(\.id).sorted()
                )
            )
        }
        return groups
    }

    private static func capabilityGroupDefinitions() -> [CapabilityGroupDefinition] {
        [
            CapabilityGroupDefinition(
                id: "core_engine",
                title: "Core Engine",
                question: "Can Tron inspect and invoke its own primitive engine?",
                narrative: "Provider execution, capability routing, settings, authentication, and model selection.",
                namespaces: ["capability", "system", "settings", "auth", "model", "registration"],
                operationFamilies: ["core", "capability_binding", "catalog_discovery"]
            ),
            CapabilityGroupDefinition(
                id: "session_context",
                title: "Session & Context",
                question: "Can Tron understand and manage the current conversation?",
                narrative: "Session state, context snapshots, compact/clear actions, goals, and message flow.",
                namespaces: ["agent", "session", "context_control", "message", "goals"],
                operationFamilies: ["state", "context_control", "goals_questions", "scheduler"]
            ),
            CapabilityGroupDefinition(
                id: "resources_memory",
                title: "Resources & Memory",
                question: "Can Tron preserve inspectable state instead of guessing?",
                narrative: "Durable resources, blobs, memory refs, filesystem-safe evidence, and replayable artifacts.",
                namespaces: ["resource", "blob", "memory", "filesystem"],
                operationFamilies: [
                    "git",
                    "filesystem",
                    "memory",
                    "media",
                    "import_history",
                    "repository_tree",
                    "import_preview",
                    "prompt_artifacts"
                ]
            ),
            CapabilityGroupDefinition(
                id: "modules",
                title: "Modules",
                question: "Can Tron author, validate, install, and govern modular abilities?",
                narrative: "Module registry, authoring, validation, install, dependency policy, and lifecycle state.",
                namespaces: [
                    "module_registry",
                    "module_authoring",
                    "module_validation",
                    "module_install",
                    "module_dependencies",
                    "module_lifecycle"
                ],
                operationFamilies: [
                    "module_registry",
                    "module_authoring",
                    "module_validation",
                    "module_install",
                    "module_dependencies",
                    "module_lifecycle",
                    "module_program_execution"
                ]
            ),
            CapabilityGroupDefinition(
                id: "runtime_workers",
                title: "Runtime & Workers",
                question: "Can Tron supervise real work without hiding runtime risk?",
                narrative: "Jobs, module runtime envelopes, worker lifecycle, generated surfaces, and bounded output refs.",
                namespaces: ["jobs", "module_runtime", "worker_lifecycle", "ui_surface"],
                operationFamilies: ["jobs", "module_runtime", "worker_packages", "program_execution", "subagents"]
            ),
            CapabilityGroupDefinition(
                id: "diagnostics_audit",
                title: "Diagnostics & Audit",
                question: "Can Tron prove what changed and why it is safe?",
                narrative: "Capability verification, module activity, approvals, agent briefing, and provider-safe evidence.",
                namespaces: ["catalog_discovery", "module_activity", "approval", "agent_briefing"],
                operationFamilies: ["trace", "logs", "update_diagnostics", "tool_sources", "web", "web_research"]
            )
        ]
    }

    private static func ownerSummary(
        workers: [AgentCockpitWorkerRow],
        functions: [AgentCockpitFunctionRow],
        operations: [AgentCockpitOperationRow],
        includesLockedOwnership: Bool
    ) -> String {
        if !operations.isEmpty {
            let locked = operations.filter(\.isLocked).count
            let replaceable = operations.filter(\.canReplace).count
            let extensible = operations.filter { $0.canExtend && !$0.canReplace }.count
            if !includesLockedOwnership {
                var summaries: [String] = []
                if replaceable > 0 { summaries.append("\(replaceable) replaceable") }
                if extensible > 0 { summaries.append("\(extensible) extensible") }
                return summaries.isEmpty
                    ? "\(operations.count) modular action\(operations.count == 1 ? "" : "s")"
                    : summaries.joined(separator: ", ")
            }
            if replaceable > 0 {
                return "\(replaceable) replaceable, \(locked) locked"
            }
            if locked > 0 {
                return "\(locked) locked action\(locked == 1 ? "" : "s")"
            }
            return "\(operations.count) governed action\(operations.count == 1 ? "" : "s")"
        }
        if !workers.isEmpty {
            return "\(workers.count) worker owner\(workers.count == 1 ? "" : "s")"
        }
        if functions.isEmpty {
            return "No published actions"
        }
        return "Built-in engine interfaces"
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

    private struct CapabilityGroupDefinition {
        var id: String
        var title: String
        var question: String
        var narrative: String
        var namespaces: Set<String>
        var operationFamilies: Set<String>

        init(
            id: String,
            title: String,
            question: String,
            narrative: String,
            namespaces: [String],
            operationFamilies: [String]
        ) {
            self.id = id
            self.title = title
            self.question = question
            self.narrative = narrative
            self.namespaces = Set(namespaces)
            self.operationFamilies = Set(operationFamilies)
        }
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
