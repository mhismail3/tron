import Foundation

@MainActor
protocol EngineConsoleCapabilityClient: AnyObject {
    func status(includeSnapshot: Bool) async throws -> CapabilityStatusDTO
    func registrySnapshot(includeDocuments: Bool, includeBindings: Bool) async throws -> CapabilityRegistrySnapshotDTO
    func controlSnapshot(limit: Int) async throws -> ControlSnapshotDTO
    func controlInspect(targetType: String, targetId: String, includeFullPayloads: Bool) async throws -> ControlInspectDTO
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
    private(set) var controlSnapshot: ControlSnapshotDTO?
    private(set) var audit: CapabilityAuditQueryResultDTO?
    private(set) var programRuns: CapabilityProgramRunQueryResultDTO?
    private(set) var policies: CapabilityPolicyGetDTO?
    private(set) var cachedSnapshot: EngineConsoleCacheSnapshot?
    var selectedInspection: CapabilityInspectionDTO?
    private(set) var programInspection: CapabilityInspectionDTO?
    private(set) var programResult: CapabilityProgramExecutionDTO?
    private(set) var programError: String?
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
        switch loadState {
        case .offlineCached: true
        default: !connectionState().isConnected
        }
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

    func inspectProgramRuntime() async {
        guard !isMutatingDisabled else { return }
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
        guard !isMutatingDisabled else { return }
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
        guard !isMutatingDisabled else { return }
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
        guard !isMutatingDisabled else { return }
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
        guard !isMutatingDisabled else { return }
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
        guard !isMutatingDisabled else { return }
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
        guard !isMutatingDisabled else { return }
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
