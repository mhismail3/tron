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
    private(set) var searchResults: [CapabilityIndexHitDTO] = []
    var searchText: String = ""

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
}
