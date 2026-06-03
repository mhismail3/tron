import Foundation

@MainActor
protocol EngineConsoleCapabilityClient: AnyObject {
    func status(includeSnapshot: Bool) async throws -> CapabilityStatusDTO
    func registrySnapshot(includeDocuments: Bool, includeBindings: Bool) async throws -> CapabilityRegistrySnapshotDTO
    func catalogWatchSnapshot(_ request: CatalogWatchSnapshotRequestDTO) async throws -> CatalogWatchSnapshotDTO
    func controlSnapshot(limit: Int) async throws -> ControlSnapshotDTO
    func controlInspect(targetType: String, targetId: String, includeFullPayloads: Bool) async throws -> ControlInspectDTO
    func inspectUiSurface(surfaceResourceId: String) async throws -> UiSurfaceInspectResultDTO
    func validateUiSurface(surfaceResourceId: String) async throws -> UiSurfaceValidationDTO
    func surfaceForTarget(
        _ request: UiSurfaceForTargetRequestDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> UiSurfaceMutationResultDTO
    func refreshUiSurface(
        _ request: UiSurfaceRefreshRequestDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> UiSurfaceMutationResultDTO
    func submitUiAction(
        _ submission: UiActionSubmissionDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> UiActionResultDTO
    func auditQuery(_ query: CapabilityAuditQueryDTO) async throws -> CapabilityAuditQueryResultDTO
    func programRunList(_ query: CapabilityProgramRunQueryDTO) async throws -> CapabilityProgramRunQueryResultDTO
    func getPolicy(policyId: String?) async throws -> CapabilityPolicyGetDTO
    func search(_ request: CapabilitySearchRequestDTO) async throws -> CapabilitySearchResponseDTO
    func inspect(
        capabilityId: String?,
        contractId: String?,
        implementationId: String?,
        functionId: String?
    ) async throws -> CapabilityInspectionDTO
    func executeProgram(
        code: String,
        args: [String: AnyCodable],
        allowedContracts: [String],
        allowedImplementations: [String],
        timeoutMs: UInt64?,
        budget: AnyCodable?,
        inspectionHandle: String,
        expectedRevision: UInt64,
        expectedSchemaDigest: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> CapabilityProgramExecutionDTO
    func setBinding(
        contractId: String,
        selectedImplementation: String,
        scopeKind: String,
        scopeValue: String,
        selectionPolicy: String,
        secondaryImplementations: [String],
        priority: Int,
        enabled: Bool,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable
    func setImplementationState(
        implementationId: String,
        state: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable
    func setPluginState(
        pluginId: String,
        state: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable
    func promotePlugin(
        pluginId: String,
        targetVisibility: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable
    func runConformance(
        pluginId: String,
        implementationId: String?,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable
}

extension CapabilityClient: EngineConsoleCapabilityClient {}

struct EngineConsoleSearchSuggestion: Equatable, Identifiable {
    var title: String
    var query: String
    var symbol: String

    var id: String { query }

    static func make(
        status: CapabilityStatusDTO?,
        registry: CapabilityRegistrySnapshotDTO?,
        catalogSnapshot: CatalogWatchSnapshotDTO?,
        controlSnapshot: ControlSnapshotDTO?,
        audit: CapabilityAuditQueryResultDTO?,
        programRuns: CapabilityProgramRunQueryResultDTO?
    ) -> [EngineConsoleSearchSuggestion] {
        var suggestions: [EngineConsoleSearchSuggestion] = []
        var seen: Set<String> = []

        func add(_ title: String, query: String, symbol: String) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty, seen.insert(trimmedQuery).inserted else { return }
            suggestions.append(
                EngineConsoleSearchSuggestion(
                    title: shortened(title, limit: 34),
                    query: trimmedQuery,
                    symbol: symbol
                )
            )
        }

        if status?.indexStatus != nil || status?.serverProfile != nil {
            add("Primer Policy", query: "capabilities.primer", symbol: "text.book.closed")
        }

        for implementation in registry?.implementations ?? [] {
            let query = implementation.functionId ?? implementation.contractId ?? implementation.implementationId
            add(query, query: query, symbol: symbol(for: query))
            if let conformance = implementation.conformanceState, !conformance.isEmpty {
                add(
                    "Conformance \(implementation.implementationId)",
                    query: "conformance \(implementation.implementationId)",
                    symbol: "checkmark.shield"
                )
            }
        }

        for document in registry?.documents ?? [] {
            let query = document.functionId
                ?? document.contractId
                ?? document.implementationId
                ?? document.workerId
                ?? document.capabilityId
            guard let query else { continue }
            add(query, query: query, symbol: symbol(for: query, kind: document.kind))
        }

        for function in catalogSnapshot?.snapshot?.functions ?? [] {
            guard let dictionary = function.dictionaryValue,
                  let query = substrateString(dictionary, keys: ["id", "functionId"]) else {
                continue
            }
            add(query, query: query, symbol: symbol(for: query))
        }

        for action in controlSnapshot?.availableActions ?? [] {
            guard let functionId = action.dictionaryValue?["functionId"] as? String else { continue }
            add(functionId, query: functionId, symbol: symbol(for: functionId))
        }

        for package in controlSnapshot?.modulePackages ?? [] {
            guard let resourceId = substrateString(package, keys: ["resourceId", "id"]) else { continue }
            add("Module \(resourceId)", query: resourceId, symbol: "shippingbox")
        }

        for surface in controlSnapshot?.uiSurfaceRefs ?? [] {
            let query = surface.surfaceId ?? surface.resourceId
            add(surface.title ?? query, query: query, symbol: "rectangle.3.group")
        }

        for event in audit?.events ?? [] {
            if let traceId = event.traceId, !traceId.isEmpty {
                add("Trace \(traceId)", query: traceId, symbol: "waterfall")
            }
            if let eventType = event.eventType, !eventType.isEmpty {
                add("Audit \(eventType)", query: eventType, symbol: "list.bullet.rectangle")
            }
        }

        for run in programRuns?.programRuns ?? [] {
            if let programRunId = run.programRunId, !programRunId.isEmpty {
                add("Program \(programRunId)", query: programRunId, symbol: "curlybraces.square")
            }
            if let traceId = run.traceId, !traceId.isEmpty {
                add("Trace \(traceId)", query: traceId, symbol: "waterfall")
            }
        }

        return Array(suggestions.prefix(18))
    }

    private static func symbol(for query: String, kind: String? = nil) -> String {
        if kind == "worker" || query.hasPrefix("worker::") {
            return "server.rack"
        }
        if query.hasPrefix("module::") {
            return "shippingbox"
        }
        if query.hasPrefix("ui::") {
            return "rectangle.3.group"
        }
        if query.hasPrefix("approval::") {
            return "checkmark.seal"
        }
        if query.hasPrefix("capability::") {
            return "sparkle.magnifyingglass"
        }
        if query.contains("conformance") {
            return "checkmark.shield"
        }
        return "function"
    }

    private static func shortened(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return "\(value[..<end])..."
    }

    private static func substrateString(_ value: AnyCodable, keys: [String]) -> String? {
        guard let dictionary = value.dictionaryValue else { return nil }
        return substrateString(dictionary, keys: keys)
    }

    private static func substrateString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }
}

@MainActor
@Observable
final class EngineConsoleState {
    enum LoadState: Equatable {
        case idle
        case loading
        case live
        case offlineCached
        case failed(String)
    }

    enum CapabilitySearchState: Equatable {
        case idle
        case loading
        case results(count: Int, degradedReason: String?)
        case empty(degradedReason: String?)
        case failed(String)
    }

    enum MutationState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    private let capabilityClient: EngineConsoleCapabilityClient
    private let connectionState: () -> ConnectionState
    private let cache: EngineConsoleCache

    private(set) var loadState: LoadState = .idle
    private(set) var status: CapabilityStatusDTO?
    private(set) var registry: CapabilityRegistrySnapshotDTO?
    private(set) var catalogSnapshot: CatalogWatchSnapshotDTO?
    private(set) var controlSnapshot: ControlSnapshotDTO?
    private(set) var audit: CapabilityAuditQueryResultDTO?
    private(set) var programRuns: CapabilityProgramRunQueryResultDTO?
    private(set) var policies: CapabilityPolicyGetDTO?
    private(set) var cachedSnapshot: EngineConsoleCacheSnapshot?
    var selectedInspection: CapabilityInspectionDTO?
    private(set) var programInspection: CapabilityInspectionDTO?
    private(set) var programResult: CapabilityProgramExecutionDTO?
    private(set) var programError: String?
    private(set) var selectedSurface: UiSurfaceInspectResultDTO?
    private(set) var surfaceActionResult: UiActionResultDTO?
    private(set) var surfaceError: String?
    private(set) var searchResults: [CapabilityIndexHitDTO] = []
    private(set) var capabilitySearchState: CapabilitySearchState = .idle
    private(set) var capabilitySearchMode: CapabilityIndexStatusDTO?
    private(set) var capabilitySearchCatalogRevision: UInt64?
    private(set) var mutationState: MutationState = .idle
    var searchText: String = ""
    var programCode: String = "return args;"
    var programArgsJSON: String = "{}"
    var programAllowedContractsText: String = ""
    var programAllowedImplementationsText: String = ""

    var isMutatingDisabled: Bool {
        readOnlyMutationReason != nil
    }

    private var readOnlyMutationReason: String? {
        switch loadState {
        case .offlineCached:
            return "Offline Engine Console cache is read-only; reconnect before submitting actions."
        default:
            return connectionState().isConnected
                ? nil
                : "Engine Console is read-only while disconnected; reconnect before submitting actions."
        }
    }

    var moduleOperatorProjection: EngineConsoleModuleOperatorProjection {
        EngineConsoleModuleOperatorProjection.make(from: controlSnapshot)
    }

    var createdByAgentProjection: EngineConsoleCreatedByAgentProjection {
        EngineConsoleCreatedByAgentProjection.make(
            registry: registry,
            catalogSnapshot: catalogSnapshot,
            controlSnapshot: controlSnapshot,
            audit: audit,
            programRuns: programRuns
        )
    }

    var substrateSearchSuggestions: [EngineConsoleSearchSuggestion] {
        EngineConsoleSearchSuggestion.make(
            status: status,
            registry: registry,
            catalogSnapshot: catalogSnapshot,
            controlSnapshot: controlSnapshot,
            audit: audit,
            programRuns: programRuns
        )
    }

    func controlAdvertisesAction(functionId: String, targetType: String? = nil) -> Bool {
        controlSnapshot?.availableActions?.contains { action in
            guard let object = action.dictionaryValue else { return false }
            guard object["functionId"] as? String == functionId else { return false }
            guard let targetType else { return true }
            let advertisedTarget = object["targetType"] as? String
            return advertisedTarget == targetType || advertisedTarget == "*"
        } ?? false
    }

    init(
        engineClient: EngineClient,
        cache: EngineConsoleCache = EngineConsoleCache()
    ) {
        self.capabilityClient = engineClient.capability
        self.connectionState = { engineClient.connectionState }
        self.cache = cache
        self.cachedSnapshot = cache.load()
    }

    init(
        capabilityClient: EngineConsoleCapabilityClient,
        connectionState: @escaping () -> ConnectionState = { .connected },
        cache: EngineConsoleCache = EngineConsoleCache()
    ) {
        self.capabilityClient = capabilityClient
        self.connectionState = connectionState
        self.cache = cache
        self.cachedSnapshot = cache.load()
    }

    func refresh() async {
        loadState = .loading
        do {
            let status = try await capabilityClient.status(includeSnapshot: false)
            let registry = try await capabilityClient.registrySnapshot(
                includeDocuments: true,
                includeBindings: true
            )
            let catalogSnapshot = try await capabilityClient.catalogWatchSnapshot(
                CatalogWatchSnapshotRequestDTO(
                    afterRevision: nil,
                    limit: 100,
                    classes: nil,
                    kinds: nil,
                    subjectPrefix: nil,
                    ownerWorker: nil
                )
            )
            let controlSnapshot = try await capabilityClient.controlSnapshot(limit: 100)
            let audit = try await capabilityClient.auditQuery(
                CapabilityAuditQueryDTO(eventType: nil, traceId: nil, limit: 50, revealPayloads: false)
            )
            let programRuns = try await capabilityClient.programRunList(
                CapabilityProgramRunQueryDTO(traceId: nil, status: nil, limit: 50, revealPayloads: false)
            )
            let policies = try await capabilityClient.getPolicy(policyId: nil)
            self.status = status
            self.registry = registry
            self.catalogSnapshot = catalogSnapshot
            self.controlSnapshot = controlSnapshot
            self.audit = audit
            self.programRuns = programRuns
            self.policies = policies
            if let programInspection,
               let inspectedCatalog = programInspection.inspectionHandle?.catalogRevision,
               let currentCatalog = status.catalogRevision,
               inspectedCatalog != currentCatalog
            {
                self.programInspection = nil
                programError = "Catalog changed; inspect the program runtime again before running."
            }
            let snapshot = EngineConsoleCache.makeSnapshot(
                status: status,
                registry: registry,
                controlSnapshot: controlSnapshot,
                audit: audit,
                programRuns: programRuns
            )
            try? cache.save(snapshot)
            cachedSnapshot = snapshot
            loadState = .live
        } catch {
            if let cached = cache.load() {
                cachedSnapshot = cached
                loadState = .offlineCached
            } else {
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    func search() async {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            capabilitySearchMode = nil
            capabilitySearchCatalogRevision = nil
            capabilitySearchState = .idle
            return
        }
        capabilitySearchState = .loading
        do {
            let response = try await capabilityClient.search(
                CapabilitySearchRequestDTO(query: searchText, limit: 25)
            )
            let results = response.results ?? []
            searchResults = results
            capabilitySearchMode = response.searchMode
            capabilitySearchCatalogRevision = response.catalogRevision
            let degradedReason = response.searchMode?.degradedReason
            capabilitySearchState = results.isEmpty
                ? .empty(degradedReason: degradedReason)
                : .results(count: results.count, degradedReason: degradedReason)
        } catch {
            searchResults = []
            capabilitySearchMode = nil
            capabilitySearchCatalogRevision = nil
            capabilitySearchState = .failed(error.localizedDescription)
        }
    }

    func inspect(_ hit: CapabilityIndexHitDTO) async {
        do {
            selectedInspection = try await capabilityClient.inspect(
                capabilityId: hit.capabilityId,
                contractId: hit.contractId,
                implementationId: hit.implementationId,
                functionId: hit.functionId
            )
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func inspectSurface(_ ref: UiSurfaceRefDTO) async {
        do {
            selectedSurface = try await capabilityClient.inspectUiSurface(surfaceResourceId: ref.resourceId)
            surfaceError = nil
        } catch {
            surfaceError = error.localizedDescription
        }
    }

    func validateSurface(_ ref: UiSurfaceRefDTO) async {
        do {
            let validation = try await capabilityClient.validateUiSurface(surfaceResourceId: ref.resourceId)
            surfaceError = validation.validationState == "valid"
                ? nil
                : "Surface \(validation.validationState)"
        } catch {
            surfaceError = error.localizedDescription
        }
    }

    func authorSurface(targetType: String, targetId: String) async {
        guard !failMutationIfReadOnly(surface: true) else { return }
        mutationState = .running("Creating generated surface")
        do {
            let request = UiSurfaceForTargetRequestDTO(
                targetType: targetType,
                targetId: targetId,
                purpose: "Inspect \(targetType) \(targetId)",
                layoutProfile: "compact",
                expectedTargetRevision: nil,
                existingSurfaceResourceId: nil,
                expectedCurrentVersionId: nil,
                resourceId: nil,
                maxPreviewBytes: 1024,
                expiresAt: nil,
                refreshPolicy: ["mode": AnyCodable("manual")],
                links: nil
            )
            let result = try await capabilityClient.surfaceForTarget(
                request,
                idempotencyKey: .userAction("ui.surface_for_target")
            )
            mutationState = .succeeded("Surface created")
            if let ref = result.resourceRefs.first {
                await inspectSurface(ref)
            }
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func refreshSelectedSurface() async {
        guard !failMutationIfReadOnly(surface: true) else { return }
        guard let ref = selectedSurface?.resourceRef,
              let versionId = ref.versionId
        else {
            surfaceError = "Select a live surface before refreshing."
            return
        }
        mutationState = .running("Refreshing generated surface")
        do {
            let result = try await capabilityClient.refreshUiSurface(
                UiSurfaceRefreshRequestDTO(
                    surfaceResourceId: ref.resourceId,
                    expectedCurrentVersionId: versionId
                ),
                idempotencyKey: .userAction("ui.refresh_surface")
            )
            mutationState = .succeeded("Surface refreshed")
            if let refreshed = result.resourceRefs.first {
                await inspectSurface(refreshed)
            }
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func submitSurfaceAction(_ submission: UiActionSubmissionDTO) async {
        guard !failMutationIfReadOnly(surface: true) else { return }
        mutationState = .running("Submitting surface action")
        do {
            surfaceActionResult = try await capabilityClient.submitUiAction(
                submission,
                idempotencyKey: .userAction("ui.submit_action")
            )
            mutationState = .succeeded("Surface action submitted")
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func inspectProgramRuntime() async {
        guard !failMutationIfReadOnly(program: true) else { return }
        do {
            programInspection = try await capabilityClient.inspect(
                capabilityId: nil,
                contractId: nil,
                implementationId: nil,
                functionId: "program::run_javascript"
            )
            programError = nil
        } catch {
            programError = error.localizedDescription
        }
    }

    func executeProgramFromInspection() async {
        guard !failMutationIfReadOnly(program: true) else { return }
        guard let inspection = programInspection else {
            programError = "Inspect the program runtime before running."
            return
        }
        guard let handle = inspection.inspectionHandle?.handle,
              let expectedRevision = inspection.inspectionHandle?.functionRevision,
              let expectedSchemaDigest = inspection.inspectionHandle?.schemaDigest
                ?? inspection.implementation?.schemaDigest
        else {
            programError = "Inspection did not include the required handle, revision, and schema digest."
            return
        }

        do {
            let args = try parseProgramArgs()
            let allowedContracts = programAllowedContractsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let allowedImplementations = programAllowedImplementationsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            programResult = try await capabilityClient.executeProgram(
                code: programCode,
                args: args,
                allowedContracts: allowedContracts,
                allowedImplementations: allowedImplementations,
                timeoutMs: nil,
                budget: nil,
                inspectionHandle: handle,
                expectedRevision: expectedRevision,
                expectedSchemaDigest: expectedSchemaDigest,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.program_run")
            )
            programError = nil
            await refresh()
        } catch {
            programError = error.localizedDescription
        }
    }

    func setImplementationState(
        implementationId: String,
        state: String
    ) async {
        guard !failMutationIfReadOnly() else { return }
        mutationState = .running("Updating implementation state")
        do {
            _ = try await capabilityClient.setImplementationState(
                implementationId: implementationId,
                state: state,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.implementation_state")
            )
            mutationState = .succeeded("Implementation updated")
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func setPluginState(pluginId: String, state: String) async {
        guard !failMutationIfReadOnly() else { return }
        mutationState = .running("Updating plugin state")
        do {
            _ = try await capabilityClient.setPluginState(
                pluginId: pluginId,
                state: state,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.plugin_state")
            )
            mutationState = .succeeded("Plugin updated")
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func runConformance(pluginId: String, implementationId: String? = nil) async {
        guard !failMutationIfReadOnly() else { return }
        mutationState = .running("Running conformance")
        do {
            _ = try await capabilityClient.runConformance(
                pluginId: pluginId,
                implementationId: implementationId,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.conformance")
            )
            mutationState = .succeeded("Conformance run completed")
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func promotePlugin(pluginId: String, targetVisibility: String = "workspace") async {
        guard !failMutationIfReadOnly() else { return }
        mutationState = .running("Promoting plugin")
        do {
            _ = try await capabilityClient.promotePlugin(
                pluginId: pluginId,
                targetVisibility: targetVisibility,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.plugin_promote")
            )
            mutationState = .succeeded("Plugin promotion requested")
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func setBindingEnabled(_ binding: CapabilityBindingDTO, enabled: Bool) async {
        guard !failMutationIfReadOnly() else { return }
        mutationState = .running(enabled ? "Enabling binding" : "Disabling binding")
        do {
            _ = try await capabilityClient.setBinding(
                contractId: binding.contractId,
                selectedImplementation: binding.selectedImplementation,
                scopeKind: binding.scopeKind ?? "system",
                scopeValue: binding.scopeValue ?? "default",
                selectionPolicy: binding.selectionPolicy ?? "explicit",
                secondaryImplementations: binding.secondaryImplementations ?? [],
                priority: binding.priority ?? 0,
                enabled: enabled,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.binding_set")
            )
            mutationState = .succeeded(enabled ? "Binding enabled" : "Binding disabled")
            await refresh()
        } catch {
            mutationState = .failed(error.localizedDescription)
        }
    }

    func clearMutationState() {
        mutationState = .idle
    }

    private func failMutationIfReadOnly(surface: Bool = false, program: Bool = false) -> Bool {
        guard let reason = readOnlyMutationReason else { return false }
        mutationState = .failed(reason)
        if surface {
            surfaceError = reason
            surfaceActionResult = nil
        }
        if program {
            programError = reason
            programResult = nil
        }
        return true
    }

    private func parseProgramArgs() throws -> [String: AnyCodable] {
        let trimmed = programArgsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw EngineConsoleStateError.invalidProgramArgs
        }
        return object.mapValues(AnyCodable.init)
    }
}

private enum EngineConsoleStateError: LocalizedError {
    case invalidProgramArgs

    var errorDescription: String? {
        switch self {
        case .invalidProgramArgs:
            "Program args must be a JSON object."
        }
    }
}
