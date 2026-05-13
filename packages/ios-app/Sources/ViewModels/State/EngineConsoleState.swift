import Foundation

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

    private let engineClient: EngineClient
    private let cache: EngineConsoleCache

    private(set) var loadState: LoadState = .idle
    private(set) var status: CapabilityStatusDTO?
    private(set) var registry: CapabilityRegistrySnapshotDTO?
    private(set) var audit: CapabilityAuditQueryResultDTO?
    private(set) var programRuns: CapabilityProgramRunQueryResultDTO?
    private(set) var policies: CapabilityPolicyGetDTO?
    private(set) var cachedSnapshot: EngineConsoleCacheSnapshot?
    var selectedInspection: CapabilityInspectionDTO?
    private(set) var programInspection: CapabilityInspectionDTO?
    private(set) var programResult: CapabilityProgramExecutionDTO?
    private(set) var programError: String?
    private(set) var searchResults: [CapabilityIndexHitDTO] = []
    var searchText: String = ""
    var programCode: String = "return args;"
    var programArgsJSON: String = "{}"
    var programAllowedContractsText: String = ""
    var programAllowedImplementationsText: String = ""

    var isMutatingDisabled: Bool {
        switch loadState {
        case .offlineCached: true
        default: !engineClient.connectionState.isConnected
        }
    }

    init(
        engineClient: EngineClient,
        cache: EngineConsoleCache = EngineConsoleCache()
    ) {
        self.engineClient = engineClient
        self.cache = cache
        self.cachedSnapshot = cache.load()
    }

    func refresh() async {
        loadState = .loading
        do {
            let status = try await engineClient.capability.status()
            let registry = try await engineClient.capability.registrySnapshot()
            let audit = try await engineClient.capability.auditQuery(
                CapabilityAuditQueryDTO(eventType: nil, traceId: nil, limit: 50, revealPayloads: false)
            )
            let programRuns = try await engineClient.capability.programRunList(
                CapabilityProgramRunQueryDTO(traceId: nil, status: nil, limit: 50, revealPayloads: false)
            )
            let policies = try await engineClient.capability.getPolicy()
            self.status = status
            self.registry = registry
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
            return
        }
        do {
            let response = try await engineClient.capability.search(
                CapabilitySearchRequestDTO(query: searchText, limit: 25)
            )
            searchResults = response.results ?? []
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func inspect(_ hit: CapabilityIndexHitDTO) async {
        do {
            selectedInspection = try await engineClient.capability.inspect(
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
            programInspection = try await engineClient.capability.inspect(
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
            programResult = try await engineClient.capability.executeProgram(
                code: programCode,
                args: args,
                allowedContracts: allowedContracts,
                allowedImplementations: allowedImplementations,
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
        do {
            _ = try await engineClient.capability.setImplementationState(
                implementationId: implementationId,
                state: state,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.implementation_state")
            )
            await refresh()
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func setPluginState(pluginId: String, state: String) async {
        guard !isMutatingDisabled else { return }
        do {
            _ = try await engineClient.capability.setPluginState(
                pluginId: pluginId,
                state: state,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.plugin_state")
            )
            await refresh()
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func runConformance(pluginId: String, implementationId: String? = nil) async {
        guard !isMutatingDisabled else { return }
        do {
            _ = try await engineClient.capability.runConformance(
                pluginId: pluginId,
                implementationId: implementationId,
                reason: "ios_engine_console",
                idempotencyKey: .userAction("capability.conformance")
            )
            await refresh()
        } catch {
            loadState = .failed(error.localizedDescription)
        }
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
