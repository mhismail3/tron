import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("EngineConsoleState")
struct EngineConsoleStateTests {
    @Test("search success records results and degraded index status")
    func searchSuccessRecordsDegradedStatus() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        client.searchResponse = CapabilitySearchResponseDTO(
            query: "read file",
            catalogRevision: 303,
            results: [
                CapabilityIndexHitDTO(
                    kind: "implementation",
                    capabilityId: "filesystem::read_file",
                    contractId: "filesystem::read_file",
                    implementationId: "first_party.filesystem.v1.read_file",
                    pluginId: "first_party.filesystem",
                    workerId: "filesystem",
                    functionId: "filesystem::read_file",
                    catalogRevision: 303,
                    schemaDigest: "sha256:read",
                    trustTier: "first_party_signed",
                    health: "healthy",
                    visibility: "system",
                    effectClass: "pure_read",
                    riskLevel: "low",
                    lexicalScore: 1,
                    vectorScore: nil,
                    fusedScore: 1,
                    matchedBy: "lexical",
                    snippet: "Read a file",
                    requiresInspect: true,
                    recipe: nil
                )
            ],
            nextCursor: nil,
            searchMode: CapabilityIndexStatusDTO(
                lexical: true,
                localVector: true,
                cloudEmbeddings: false,
                vectorStore: "sqlite-vec",
                embeddingModel: "fastembed:test",
                state: "unavailable",
                degradedReason: "embedding assets unavailable",
                dimension: 384,
                updatedAt: nil
            )
        )
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())
        state.searchText = "read file"

        await state.search()

        #expect(client.lastSearchQuery == "read file")
        #expect(state.searchResults.count == 1)
        #expect(state.capabilitySearchMode?.state == "unavailable")
        #expect(state.capabilitySearchState == .results(count: 1, degradedReason: "embedding assets unavailable"))
    }

    @Test("empty search clears local search state")
    func emptySearchClearsResults() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())
        state.searchText = "   "

        await state.search()

        #expect(client.lastSearchQuery == nil)
        #expect(state.searchResults.isEmpty)
        #expect(state.capabilitySearchState == .idle)
    }

    @Test("search failure is local to capabilities section")
    func searchFailureDoesNotReplaceConsoleLoadState() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        client.searchError = EngineConnectionError.invalidResponse
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())
        state.searchText = "read file"

        await state.search()

        #expect(state.searchResults.isEmpty)
        guard case .failed(let message) = state.capabilitySearchState else {
            Issue.record("Expected local search failure")
            return
        }
        #expect(!message.isEmpty)
        #expect(state.loadState == .idle)
    }

    @Test("offline cached state disables mutations")
    func offlineCachedStateDisablesMutations() async throws {
        let cache = ephemeralCache()
        try cache.save(
            EngineConsoleCacheSnapshot(
                catalogRevision: 1,
                registryRevision: 1,
                pluginSummaries: [],
                workerSummaries: [],
                recentAuditRows: [],
                recentTraceSummaries: [],
                recentProgramRuns: [],
                indexStatus: nil,
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let client = FakeEngineConsoleCapabilityClient()
        client.statusError = EngineConnectionError.notConnected
        let state = EngineConsoleState(
            capabilityClient: client,
            connectionState: { .disconnected },
            cache: cache
        )

        await state.refresh()

        #expect(state.isMutatingDisabled)
        #expect(state.loadState == .offlineCached)
    }

    @Test("plugin mutation records local action state without failing console")
    func pluginMutationUsesLocalMutationState() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())

        await state.setPluginState(pluginId: "session.generated", state: "quarantined")

        #expect(state.mutationState == .succeeded("Plugin updated"))
        #expect(state.loadState == .live)
    }

    @Test("binding mutation keeps capability policy details out of the main load state")
    func bindingMutationUsesLocalMutationState() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())
        let binding = CapabilityBindingDTO(
            contractId: "filesystem::read_file",
            scopeKind: "system",
            scopeValue: "default",
            selectedImplementation: "first_party.filesystem.v1.read_file",
            selectionPolicy: "explicit",
            secondaryImplementations: [],
            enabled: true,
            priority: 0,
            updatedAt: nil
        )

        await state.setBindingEnabled(binding, enabled: false)

        #expect(state.mutationState == .succeeded("Binding disabled"))
        #expect(state.loadState == .live)
    }

    private func ephemeralCache() -> EngineConsoleCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("EngineConsoleCache.json")
        return EngineConsoleCache(fileURL: url)
    }
}

@MainActor
private final class FakeEngineConsoleCapabilityClient: EngineConsoleCapabilityClient {
    var searchResponse = CapabilitySearchResponseDTO(
        query: nil,
        catalogRevision: nil,
        results: [],
        nextCursor: nil,
        searchMode: nil
    )
    var searchError: Error?
    var statusError: Error?
    var lastSearchQuery: String?

    func status(includeSnapshot: Bool) async throws -> CapabilityStatusDTO {
        if let statusError { throw statusError }
        return CapabilityStatusDTO(catalogRevision: 1, registryRevision: 1)
    }

    func registrySnapshot(
        includeDocuments: Bool,
        includeBindings: Bool
    ) async throws -> CapabilityRegistrySnapshotDTO {
        CapabilityRegistrySnapshotDTO(plugins: [], implementations: [], bindings: [], documents: [], programRuns: [])
    }

    func auditQuery(_ query: CapabilityAuditQueryDTO) async throws -> CapabilityAuditQueryResultDTO {
        CapabilityAuditQueryResultDTO(events: [], redacted: true)
    }

    func programRunList(_ query: CapabilityProgramRunQueryDTO) async throws -> CapabilityProgramRunQueryResultDTO {
        CapabilityProgramRunQueryResultDTO(programRuns: [], redacted: true)
    }

    func getPolicy(policyId: String?) async throws -> CapabilityPolicyGetDTO {
        CapabilityPolicyGetDTO(
            profileName: "default",
            profileHash: "hash",
            policyId: policyId,
            primitiveSurfacePolicies: [:],
            capabilityExecutionPolicies: [:]
        )
    }

    func search(_ request: CapabilitySearchRequestDTO) async throws -> CapabilitySearchResponseDTO {
        lastSearchQuery = request.query
        if let searchError { throw searchError }
        return searchResponse
    }

    func inspect(
        capabilityId: String?,
        contractId: String?,
        implementationId: String?,
        functionId: String?
    ) async throws -> CapabilityInspectionDTO {
        CapabilityInspectionDTO(
            contract: nil,
            implementation: nil,
            binding: nil,
            bindingDecision: nil,
            inspectionHandle: nil,
            recipe: nil,
            executionRequirements: nil,
            docs: nil
        )
    }

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
    ) async throws -> CapabilityProgramExecutionDTO {
        CapabilityProgramExecutionDTO(
            status: "ok",
            output: nil,
            error: nil,
            traceId: "trace",
            programRunId: "program_run_test",
            parentInvocationId: nil,
            rootInvocationId: "root",
            bindingDecisionId: nil,
            codeHash: "code",
            argsHash: "args",
            childInvocations: [],
            selectedImplementations: [],
            approvalState: nil,
            artifacts: [],
            logs: [],
            compensationAttempts: []
        )
    }

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
    ) async throws -> AnyCodable {
        AnyCodable(["updated": true])
    }

    func setImplementationState(
        implementationId: String,
        state: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        AnyCodable(["updated": true])
    }

    func setPluginState(
        pluginId: String,
        state: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        AnyCodable(["updated": true])
    }

    func promotePlugin(
        pluginId: String,
        targetVisibility: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        AnyCodable(["promoted": true])
    }

    func runConformance(
        pluginId: String,
        implementationId: String?,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        AnyCodable(["queued": true])
    }
}
