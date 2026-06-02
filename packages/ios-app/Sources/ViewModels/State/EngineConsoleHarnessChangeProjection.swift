import Foundation

struct EngineConsoleHarnessChangeProjection: Equatable {
    var changes: [EngineConsoleHarnessChangeSummary]

    static let empty = EngineConsoleHarnessChangeProjection(changes: [])

    var isEmpty: Bool { changes.isEmpty }

    static func make(
        registry: CapabilityRegistrySnapshotDTO?,
        controlSnapshot: ControlSnapshotDTO?,
        audit: CapabilityAuditQueryResultDTO?,
        programRuns: CapabilityProgramRunQueryResultDTO?
    ) -> EngineConsoleHarnessChangeProjection {
        let sessionImplementations = (registry?.implementations ?? [])
            .filter(isSessionCreated)
        let changes = sessionImplementations
            .compactMap { implementation in
                EngineConsoleHarnessChangeSummary(
                    implementation: implementation,
                    controlSnapshot: controlSnapshot,
                    audit: audit,
                    programRuns: programRuns
                )
            }
        return EngineConsoleHarnessChangeProjection(changes: changes)
    }

    private static func isSessionCreated(_ implementation: CapabilityImplementationDTO) -> Bool {
        if implementation.visibility == "session" {
            return true
        }
        if implementation.trustTier?.contains("session") == true {
            return true
        }
        if let provenance = implementation.provenance?.dictionaryValue,
           harnessString(provenance, keys: ["sessionId", "session_id"]) != nil {
            return true
        }
        return false
    }
}

struct EngineConsoleHarnessChangeSummary: Equatable, Identifiable {
    var implementationId: String
    var functionId: String
    var contractId: String?
    var workerId: String?
    var pluginId: String?
    var provenanceText: String
    var testText: String
    var generatedSurfaceIds: [String]
    var promotionText: String
    var cleanupText: String
    var traceIds: [String]
    var programRunIds: [String]
    var childInvocationIds: [String]

    var id: String { implementationId }

    var title: String { functionId }

    var subtitle: String {
        [
            implementationId,
            workerId
        ]
        .compactMap { $0 }
        .joined(separator: " / ")
    }

    var evidenceValues: [String] {
        [
            "Provenance \(provenanceText)",
            "Tests \(testText)",
            "Generated UI \(generatedSurfaceIds.isEmpty ? "none" : generatedSurfaceIds.joined(separator: ", "))",
            "Promotion \(promotionText)",
            "Cleanup \(cleanupText)",
            "Trace \(traceIds.isEmpty ? "none" : traceIds.joined(separator: ", "))"
        ]
    }

    var accessibilityLabel: String {
        "Harness change \(functionId)"
    }

    var accessibilityValue: String {
        evidenceValues.joined(separator: ", ")
    }

    init?(
        implementation: CapabilityImplementationDTO,
        controlSnapshot: ControlSnapshotDTO?,
        audit: CapabilityAuditQueryResultDTO?,
        programRuns: CapabilityProgramRunQueryResultDTO?
    ) {
        let functionId = implementation.functionId ?? implementation.contractId ?? implementation.implementationId
        let identifiers = Self.identifiers(for: implementation, functionId: functionId)
        let matchingSurfaces = (controlSnapshot?.uiSurfaceRefs ?? [])
            .filter { surface in
                Self.surface(surface, matches: identifiers)
            }
        let matchingRuns = (programRuns?.programRuns ?? [])
            .filter { run in
                Self.programRun(run, matches: implementation, identifiers: identifiers)
            }
        let matchingTraceIds = Set(matchingRuns.compactMap(\.traceId))
        let matchingEvents = (audit?.events ?? [])
            .filter { event in
                Self.auditEvent(event, matches: identifiers, traceIds: matchingTraceIds)
            }

        self.implementationId = implementation.implementationId
        self.functionId = functionId
        self.contractId = implementation.contractId
        self.workerId = implementation.workerId
        self.pluginId = implementation.pluginId
        self.provenanceText = Self.provenanceText(for: implementation)
        self.testText = implementation.conformanceState ?? "unknown"
        self.generatedSurfaceIds = Self.unique(
            matchingSurfaces.map { $0.surfaceId ?? $0.resourceId }
        )
        self.promotionText = implementation.visibility ?? "unknown"
        self.cleanupText = Self.cleanupText(
            implementation: implementation,
            controlSnapshot: controlSnapshot,
            events: matchingEvents
        )
        self.traceIds = Self.unique(
            matchingRuns.compactMap(\.traceId) + matchingEvents.compactMap(\.traceId)
        )
        self.programRunIds = Self.unique(matchingRuns.compactMap(\.programRunId))
        self.childInvocationIds = Self.unique(matchingRuns.flatMap { $0.childInvocations ?? [] })
    }

    private static func identifiers(
        for implementation: CapabilityImplementationDTO,
        functionId: String
    ) -> Set<String> {
        Set([
            functionId,
            implementation.implementationId,
            implementation.contractId,
            implementation.workerId,
            implementation.pluginId
        ].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        })
    }

    private static func provenanceText(for implementation: CapabilityImplementationDTO) -> String {
        if let provenance = implementation.provenance?.dictionaryValue {
            if let sessionId = harnessString(provenance, keys: ["sessionId", "session_id"]) {
                return "session \(sessionId)"
            }
            if let workspaceId = harnessString(provenance, keys: ["workspaceId", "workspace_id"]) {
                return "workspace \(workspaceId)"
            }
            if let source = harnessString(provenance, keys: ["source", "createdBy", "actor"]) {
                return source
            }
        }
        return implementation.trustTier ?? "unknown"
    }

    private static func surface(_ surface: UiSurfaceRefDTO, matches identifiers: Set<String>) -> Bool {
        for target in surface.targets ?? [] {
            if let targetId = target.targetId, identifiers.contains(targetId) {
                return true
            }
        }
        for action in surface.actions ?? [] {
            if let targetFunctionId = action.targetFunctionId, identifiers.contains(targetFunctionId) {
                return true
            }
        }
        for value in [surface.surfaceId, surface.title, surface.purpose, surface.resourceId] {
            if text(value, containsAny: identifiers) {
                return true
            }
        }
        return false
    }

    private static func programRun(
        _ run: CapabilityProgramRunDTO,
        matches implementation: CapabilityImplementationDTO,
        identifiers: Set<String>
    ) -> Bool {
        if let selected = run.selectedImplementations, selected.contains(implementation.implementationId) {
            return true
        }
        if let allowed = run.allowedImplementations, allowed.contains(implementation.implementationId) {
            return true
        }
        if let contractId = implementation.contractId,
           let allowed = run.allowedContracts,
           allowed.contains(contractId) {
            return true
        }
        if let payloadSummary = run.payloadSummary {
            return anyValue(payloadSummary.value, containsAny: identifiers)
        }
        return false
    }

    private static func auditEvent(
        _ event: CapabilityAuditEventDTO,
        matches identifiers: Set<String>,
        traceIds: Set<String>
    ) -> Bool {
        if let traceId = event.traceId, traceIds.contains(traceId) {
            return true
        }
        if let summary = event.payloadSummary?.dictionaryValue,
           dictionaryContains(summary, identifiers: identifiers) {
            return true
        }
        if let payload = event.payload?.dictionaryValue,
           dictionaryContains(payload, identifiers: identifiers) {
            return true
        }
        return false
    }

    private static func cleanupText(
        implementation: CapabilityImplementationDTO,
        controlSnapshot: ControlSnapshotDTO?,
        events: [CapabilityAuditEventDTO]
    ) -> String {
        if let cleanupEvent = events.first(where: { event in
            let eventType = event.eventType?.lowercased() ?? ""
            return eventType.contains("cleanup")
                || eventType.contains("disconnect")
                || eventType.contains("unregister")
        }) {
            return cleanupEvent.eventType ?? "recorded"
        }
        if let workerId = implementation.workerId,
           let worker = (controlSnapshot?.workers ?? []).first(where: { worker in
               guard let dictionary = worker.dictionaryValue else { return false }
               return harnessString(dictionary, keys: ["workerId", "id"]) == workerId
           }),
           let dictionary = worker.dictionaryValue {
            return harnessString(dictionary, keys: ["lifecycle", "status", "health"]) ?? "active"
        }
        return "not recorded"
    }

    private static func text(_ value: String?, containsAny identifiers: Set<String>) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return identifiers.contains { identifier in
            value.contains(identifier)
        }
    }

    private static func dictionaryContains(_ dictionary: [String: Any], identifiers: Set<String>) -> Bool {
        dictionary.values.contains { value in
            anyValue(value, containsAny: identifiers)
        }
    }

    private static func anyValue(_ value: Any, containsAny identifiers: Set<String>) -> Bool {
        switch value {
        case let string as String:
            text(string, containsAny: identifiers)
        case let nested as [String: Any]:
            dictionaryContains(nested, identifiers: identifiers)
        case let array as [Any]:
            array.contains { item in
                anyValue(item, containsAny: identifiers)
            }
        default:
            false
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }
}

private func harnessString(_ dictionary: [String: Any]?, keys: [String]) -> String? {
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
