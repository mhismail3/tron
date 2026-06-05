import Foundation

struct AuditDetailsWorkerArtifactProjection: Equatable {
    var changes: [AuditDetailsWorkerArtifactSummary]

    static let empty = AuditDetailsWorkerArtifactProjection(changes: [])

    var isEmpty: Bool { changes.isEmpty }

    static func make(
        registry: CapabilityRegistrySnapshotDTO?,
        catalogSnapshot: CatalogWatchSnapshotDTO?,
        controlSnapshot: ControlSnapshotDTO?,
        audit: CapabilityAuditQueryResultDTO?,
        programRuns: CapabilityProgramRunQueryResultDTO?
    ) -> AuditDetailsWorkerArtifactProjection {
        let sessionImplementations = uniqueImplementations(
            (registry?.implementations ?? []) + catalogImplementations(from: catalogSnapshot)
        )
            .filter(isSessionCreated)
        let changes = sessionImplementations
            .compactMap { implementation in
                AuditDetailsWorkerArtifactSummary(
                    implementation: implementation,
                    controlSnapshot: controlSnapshot,
                    audit: audit,
                    programRuns: programRuns
                )
            }
        return AuditDetailsWorkerArtifactProjection(changes: changes)
    }

    private static func isSessionCreated(_ implementation: CapabilityImplementationDTO) -> Bool {
        if implementation.visibility?.lowercased() == "session" {
            return true
        }
        if implementation.trustTier?.lowercased().contains("session") == true {
            return true
        }
        if let provenance = implementation.provenance?.dictionaryValue,
           workerArtifactsString(provenance, keys: ["sessionId", "session_id"]) != nil {
            return true
        }
        return false
    }

    private static func catalogImplementations(
        from catalogSnapshot: CatalogWatchSnapshotDTO?
    ) -> [CapabilityImplementationDTO] {
        (catalogSnapshot?.snapshot?.functions ?? []).compactMap { function in
            guard let dictionary = function.dictionaryValue,
                  let functionId = workerArtifactsString(dictionary, keys: ["id", "functionId", "function_id"]) else {
                return nil
            }
            let metadata = workerArtifactsDictionary(dictionary, keys: ["metadata"])
            let provenance = workerArtifactsDictionary(dictionary, keys: ["provenance"])
            let workerId = workerArtifactsString(dictionary, keys: ["owner_worker", "ownerWorker", "workerId", "worker_id"])
            let implementationId = workerArtifactsString(
                metadata,
                keys: ["implementationId", "implementation_id"]
            ) ?? "catalog.\(workerId ?? "worker").\(functionId)"
            let health = workerArtifactsString(dictionary, keys: ["health"])

            return CapabilityImplementationDTO(
                implementationId: implementationId,
                contractId: workerArtifactsString(metadata, keys: ["contractId", "contract_id"])
                    ?? workerArtifactsString(dictionary, keys: ["contractId", "contract_id"])
                    ?? functionId,
                pluginId: workerArtifactsString(metadata, keys: ["pluginId", "plugin_id"])
                    ?? workerArtifactsString(dictionary, keys: ["pluginId", "plugin_id"]),
                workerId: workerId,
                functionId: functionId,
                version: workerArtifactsUInt64(dictionary, keys: ["revision", "version"]),
                health: health,
                visibility: workerArtifactsString(dictionary, keys: ["visibility"]),
                latencyClass: workerArtifactsString(metadata, keys: ["latencyClass", "latency_class"]),
                costClass: workerArtifactsString(metadata, keys: ["costClass", "cost_class"]),
                trustTier: workerArtifactsString(metadata, keys: ["trustTier", "trust_tier"]),
                authorityRequirements: workerArtifactsAnyCodable(
                    dictionary,
                    keys: ["authorityRequirements", "authority_requirements"]
                ),
                runtimeRequirements: workerArtifactsAnyCodable(
                    dictionary,
                    keys: ["runtimeRequirements", "runtime_requirements"]
                ),
                schemaDigest: workerArtifactsString(metadata, keys: ["schemaDigest", "schema_digest"])
                    ?? workerArtifactsString(dictionary, keys: ["schemaDigest", "schema_digest"]),
                catalogRevision: catalogSnapshot?.currentRevision,
                provenance: provenance.map(AnyCodable.init),
                conformanceState: workerArtifactsString(metadata, keys: ["conformanceState", "conformance_state"]) ?? health,
                signatureStatus: workerArtifactsString(metadata, keys: ["signatureStatus", "signature_status"]) ?? "catalog",
                updatedAt: workerArtifactsString(dictionary, keys: ["updatedAt", "updated_at"])
            )
        }
    }

    private static func uniqueImplementations(
        _ implementations: [CapabilityImplementationDTO]
    ) -> [CapabilityImplementationDTO] {
        var seen: Set<String> = []
        var unique: [CapabilityImplementationDTO] = []
        for implementation in implementations where seen.insert(implementation.implementationId).inserted {
            unique.append(implementation)
        }
        return unique
    }
}

struct AuditDetailsWorkerArtifactSummary: Equatable, Identifiable {
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
    var shelfTitle: String
    var shelfSubtitle: String
    var historyLabels: [String]

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
        "Created by agent capability \(shelfTitle)"
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
        self.shelfTitle = Self.shelfTitle(for: implementation, functionId: functionId)
        self.shelfSubtitle = Self.shelfSubtitle(for: implementation)
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
        self.historyLabels = Self.historyLabels(
            implementation: implementation,
            events: matchingEvents,
            programRuns: matchingRuns
        )
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
            if let sessionId = workerArtifactsString(provenance, keys: ["sessionId", "session_id"]) {
                return "session \(sessionId)"
            }
            if let workspaceId = workerArtifactsString(provenance, keys: ["workspaceId", "workspace_id"]) {
                return "workspace \(workspaceId)"
            }
            if let source = workerArtifactsString(provenance, keys: ["source", "createdBy", "actor"]) {
                return source
            }
        }
        return implementation.trustTier ?? "unknown"
    }

    private static func shelfTitle(
        for implementation: CapabilityImplementationDTO,
        functionId: String
    ) -> String {
        if let provenance = implementation.provenance?.dictionaryValue,
           let title = workerArtifactsString(provenance, keys: ["displayName", "display_name", "title", "name"]) {
            return humanizedCapabilityLabel(title)
        }
        if let contractId = implementation.contractId,
           contractId != functionId,
           !contractId.hasPrefix("capability::") {
            return humanizedCapabilityLabel(contractId)
        }
        return humanizedCapabilityLabel(functionId)
    }

    private static func shelfSubtitle(for implementation: CapabilityImplementationDTO) -> String {
        if let provenance = implementation.provenance?.dictionaryValue {
            let source = workerArtifactsString(provenance, keys: ["createdBy", "created_by", "actor", "source"])?
                .lowercased()
            if source?.contains("agent") == true {
                return "Created by agent"
            }
            if source?.contains("user") == true {
                return "Created by user"
            }
        }
        if implementation.visibility?.lowercased() == "workspace" {
            return "Available in this workspace"
        }
        return "Created by agent"
    }

    private static func historyLabels(
        implementation: CapabilityImplementationDTO,
        events: [CapabilityAuditEventDTO],
        programRuns: [CapabilityProgramRunDTO]
    ) -> [String] {
        var labels: [String] = []
        appendUnique("Created", to: &labels)
        if implementation.updatedAt != nil || eventMatches(events, terms: ["updated", "upgrade", "refreshed"]) {
            appendUnique("Updated", to: &labels)
        }
        if eventMatches(events, terms: ["auto_repaired", "autorepaired", "repair"]) {
            appendUnique("Auto-repaired", to: &labels)
        }
        if tested(implementation: implementation, events: events, programRuns: programRuns) {
            appendUnique("Tested", to: &labels)
        }
        if failed(events: events, programRuns: programRuns) {
            appendUnique("Failed", to: &labels)
        }
        if promoted(implementation: implementation, events: events) {
            appendUnique("Promoted", to: &labels)
        }
        if eventMatches(events, terms: ["revoked", "revocation"]) {
            appendUnique("Revoked", to: &labels)
        }
        if eventMatches(events, terms: ["discard", "discarded", "deleted", "removed"]) {
            appendUnique("Discarded", to: &labels)
        }
        if !programRuns.isEmpty || eventMatches(events, terms: ["reused", "executed", "invoked", "capability.execute"]) {
            appendUnique("Reused", to: &labels)
        }
        return labels
    }

    private static func tested(
        implementation: CapabilityImplementationDTO,
        events: [CapabilityAuditEventDTO],
        programRuns: [CapabilityProgramRunDTO]
    ) -> Bool {
        if let conformance = implementation.conformanceState?.lowercased(),
           ["passed", "healthy", "accepted", "ok"].contains(conformance) {
            return true
        }
        if eventMatches(events, terms: ["test_passed", "conformance", "validated"]) {
            return true
        }
        return programRuns.contains { run in
            guard let status = run.status?.lowercased() else { return false }
            return ["ok", "passed", "succeeded", "success"].contains(status)
        }
    }

    private static func failed(
        events: [CapabilityAuditEventDTO],
        programRuns: [CapabilityProgramRunDTO]
    ) -> Bool {
        if eventMatches(events, terms: ["test_failed", "failed", "error"]) {
            return true
        }
        return programRuns.contains { run in
            guard let status = run.status?.lowercased() else { return false }
            return ["failed", "error", "errored"].contains(status)
        }
    }

    private static func promoted(
        implementation: CapabilityImplementationDTO,
        events: [CapabilityAuditEventDTO]
    ) -> Bool {
        if ["workspace", "system"].contains(implementation.visibility?.lowercased()) {
            return true
        }
        return eventMatches(events, terms: ["promoted", "promotion"])
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
               return workerArtifactsString(dictionary, keys: ["workerId", "id"]) == workerId
           }),
           let dictionary = worker.dictionaryValue {
            return workerArtifactsString(dictionary, keys: ["lifecycle", "status", "health"]) ?? "active"
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

    private static func eventMatches(_ events: [CapabilityAuditEventDTO], terms: [String]) -> Bool {
        events.contains { event in
            let text = [
                event.eventType,
                event.id,
                event.payloadSummary.map { flattenedText($0.value) },
                event.payload.map { flattenedText($0.value) }
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            return terms.contains { text.contains($0) }
        }
    }

    private static func flattenedText(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let codable as AnyCodable:
            return flattenedText(codable.value)
        case let dictionary as [String: Any]:
            return dictionary
                .map { "\($0.key) \(flattenedText($0.value))" }
                .joined(separator: " ")
        case let array as [Any]:
            return array.map(flattenedText).joined(separator: " ")
        default:
            return String(describing: value)
        }
    }

    private static func humanizedCapabilityLabel(_ value: String) -> String {
        let base = value
            .components(separatedBy: "::")
            .first
            ?? value
        let words = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0).lowercased() }
        guard let first = words.first else { return "Capability" }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    private static func appendUnique(_ value: String, to labels: inout [String]) {
        if !labels.contains(value) {
            labels.append(value)
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

private func workerArtifactsString(_ dictionary: [String: Any]?, keys: [String]) -> String? {
    guard let dictionary else { return nil }
    for key in keys {
        if let value = dictionary[key] as? AnyCodable {
            return workerArtifactsStringValue(value.value)
        }
        if let uint = dictionary[key] as? UInt64 {
            return String(uint)
        }
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

private func workerArtifactsStringValue(_ value: Any) -> String? {
    switch value {
    case let string as String where !string.isEmpty:
        return string
    case let uint as UInt64:
        return String(uint)
    case let int as Int:
        return String(int)
    case let double as Double:
        return String(double)
    case let bool as Bool:
        return bool ? "true" : "false"
    case let codable as AnyCodable:
        return workerArtifactsStringValue(codable.value)
    default:
        return nil
    }
}

private func workerArtifactsDictionary(_ dictionary: [String: Any], keys: [String]) -> [String: Any]? {
    for key in keys {
        if let nested = dictionary[key] as? [String: Any] {
            return nested
        }
        if let codable = dictionary[key] as? AnyCodable,
           let nested = codable.dictionaryValue {
            return nested
        }
    }
    return nil
}

private func workerArtifactsUInt64(_ dictionary: [String: Any], keys: [String]) -> UInt64? {
    for key in keys {
        switch dictionary[key] {
        case let value as UInt64:
            return value
        case let value as Int where value >= 0:
            return UInt64(value)
        case let value as Double where value >= 0:
            return UInt64(exactly: value.rounded(.towardZero))
        case let value as AnyCodable:
            if let int = value.intValue, int >= 0 {
                return UInt64(int)
            }
            if let double = value.doubleValue, double >= 0 {
                return UInt64(exactly: double.rounded(.towardZero))
            }
            if let string = value.stringValue, let parsed = UInt64(string) {
                return parsed
            }
        case let value as String:
            if let parsed = UInt64(value) {
                return parsed
            }
        default:
            continue
        }
    }
    return nil
}

private func workerArtifactsAnyCodable(_ dictionary: [String: Any], keys: [String]) -> AnyCodable? {
    for key in keys {
        guard let raw = dictionary[key] else { continue }
        if let codable = raw as? AnyCodable {
            return codable
        }
        return AnyCodable(raw)
    }
    return nil
}
