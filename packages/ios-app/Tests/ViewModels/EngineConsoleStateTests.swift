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
                controlSnapshot: nil,
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

    @Test("refresh loads read-only control snapshot")
    func refreshLoadsControlSnapshot() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        client.controlSnapshot = ControlSnapshotDTO(
            catalogRevision: 7,
            workers: [AnyCodable(["id": "resource"])],
            capabilities: [AnyCodable(["id": "resource::create"])],
            resourceTypes: [AnyCodable(["kind": "goal"])],
            activeGoals: [],
            modulePackages: [AnyCodable(["resourceId": "worker-package:demo"])],
            moduleConfigs: [AnyCodable(["resourceId": "module-config:workspace:demo"])],
            activationRecords: [AnyCodable(["resourceId": "activation:workspace:demo"])],
            invocations: [],
            grants: [],
            queues: [],
            leases: [],
            approvals: [],
            storage: nil,
            integrityWarnings: [],
            availableActions: [AnyCodable(["functionId": "worker::disconnect"])]
        )
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())

        await state.refresh()

        #expect(state.controlSnapshot?.catalogRevision == 7)
        #expect(state.controlSnapshot?.modulePackages?.count == 1)
        #expect(state.controlSnapshot?.moduleConfigs?.count == 1)
        #expect(state.controlSnapshot?.activationRecords?.count == 1)
        #expect(state.cachedSnapshot?.controlSnapshot?.catalogRevision == 7)
    }

    @Test("server advertised actions gate generated surface authoring")
    func serverAdvertisedActionsGateGeneratedSurfaceAuthoring() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        client.controlSnapshot = ControlSnapshotDTO(
            catalogRevision: 7,
            workers: [AnyCodable(["id": "resource"])],
            capabilities: [],
            resourceTypes: [],
            activeGoals: [],
            invocations: [],
            grants: [],
            queues: [],
            leases: [],
            approvals: [],
            storage: nil,
            integrityWarnings: [],
            availableActions: []
        )
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())

        await state.refresh()
        #expect(!state.controlAdvertisesAction(functionId: "ui::surface_for_target", targetType: "worker"))

        client.controlSnapshot.availableActions = [
            AnyCodable(["functionId": "ui::surface_for_target", "targetType": "worker"])
        ]
        await state.refresh()
        #expect(state.controlAdvertisesAction(functionId: "ui::surface_for_target", targetType: "worker"))
        #expect(!state.controlAdvertisesAction(functionId: "ui::surface_for_target", targetType: "grant"))

        client.controlSnapshot.availableActions = [
            AnyCodable(["functionId": "ui::surface_for_target", "targetType": "*"])
        ]
        await state.refresh()
        #expect(state.controlAdvertisesAction(functionId: "ui::surface_for_target", targetType: "grant"))
    }

    @Test("module operator projection keeps server actions and evidence")
    func moduleOperatorProjectionKeepsServerActionsAndEvidence() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        client.controlSnapshot = ControlSnapshotDTO(
            catalogRevision: 9,
            workers: [],
            capabilities: [],
            resourceTypes: [],
            activeGoals: [],
            modulePackages: [
                AnyCodable([
                    "resourceId": "worker-package:demo",
                    "currentVersionId": "pkg-v1",
                    "lifecycle": "available"
                ])
            ],
            moduleConfigs: [
                AnyCodable([
                    "resourceId": "module-config:workspace:demo",
                    "currentVersionId": "cfg-v1",
                    "lifecycle": "available"
                ])
            ],
            activationRecords: [
                AnyCodable([
                    "resourceId": "activation:workspace:demo",
                    "currentVersionId": "act-v1",
                    "lifecycle": "available"
                ])
            ],
            moduleHealth: [
                AnyCodable([
                    "activationResourceId": "activation:workspace:demo",
                    "activationVersionId": "act-v1",
                    "activationStatus": "active",
                    "workerId": "demo-worker",
                    "healthResult": ["status": "healthy"],
                    "healthEvidenceRef": "evidence:health"
                ])
            ],
            moduleSourceTrust: [
                AnyCodable([
                    "packageResourceId": "worker-package:demo",
                    "packageVersionId": "pkg-v1",
                    "packageId": "demo",
                    "sourceTrustStatus": "verified",
                    "effectiveTrustTier": "local_digest_verified",
                    "sourceEvidenceRefs": ["evidence:source"],
                    "sourceRegistrationRefs": [
                        ["resourceId": "decision:source-registration"]
                    ],
                    "trustRootRefs": [
                        ["resourceId": "decision:trust-root"]
                    ],
                    "sourceApprovalRefs": [
                        ["resourceId": "decision:source-approval", "status": "active"]
                    ],
                    "conformanceEvidenceRefs": ["evidence:conformance"],
                    "policyDiagnostics": ["conformance": ["evidenceRef": "evidence:conformance"]]
                ])
            ],
            invocations: [],
            grants: [],
            queues: [],
            leases: [],
            approvals: [],
            storage: nil,
            integrityWarnings: [],
            availableActions: [
                moduleAction("module::configure", targetType: "package", targetField: "packageResourceId", risk: "medium", approvalRequired: false),
                moduleAction("module::activate", targetType: "package", targetField: "packageResourceId", risk: "high", approvalRequired: true),
                moduleAction("module::disable", targetType: "activation", targetField: "activationResourceId", risk: "high", approvalRequired: true),
                moduleAction("module::rollback", targetType: "activation", targetField: "activationResourceId", risk: "high", approvalRequired: true),
                moduleAction("module::quarantine", targetType: "activation", targetField: "resourceId", risk: "high", approvalRequired: true),
                moduleAction("module::verify_source", targetType: "package", targetField: "packageResourceId", risk: "medium", approvalRequired: false),
                moduleAction("module::approve_source", targetType: "package", targetField: "packageResourceId", risk: "high", approvalRequired: true),
                moduleAction("module::run_conformance", targetType: "package", targetField: "resourceId", risk: "medium", approvalRequired: false),
                moduleAction("module::simulate_trust_change", targetType: "package", targetField: "targetResourceId", risk: "low", approvalRequired: false),
                moduleAction("module::record_trust_review", targetType: "package", targetField: "targetResourceId", risk: "medium", approvalRequired: false),
                moduleAction("module::custom_future_operation", targetType: "package", targetField: "packageResourceId", risk: "medium", approvalRequired: false),
                AnyCodable(["functionId": "worker::disconnect", "targetType": "worker"])
            ]
        )
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())

        await state.refresh()

        let projection = state.moduleOperatorProjection
        #expect(projection.packages.map(\.resourceId) == ["worker-package:demo"])
        #expect(projection.configs.map(\.resourceId) == ["module-config:workspace:demo"])
        #expect(projection.activations.map(\.resourceId) == ["activation:workspace:demo"])
        #expect(projection.health.first?.healthEvidenceRef == "evidence:health")
        #expect(projection.sourceTrust.first?.sourceEvidenceRefs == ["evidence:source"])
        #expect(projection.sourceTrust.first?.sourceRegistrationRefs == ["decision:source-registration"])
        #expect(projection.sourceTrust.first?.trustRootRefs == ["decision:trust-root"])
        #expect(projection.sourceTrust.first?.sourceApprovalRefs == ["decision:source-approval"])
        #expect(projection.sourceTrust.first?.conformanceEvidenceRefs == ["evidence:conformance"])
        #expect(projection.evidenceRefCount == 6)

        let actionIds = Set(projection.actions.map(\.functionId))
        for required in [
            "module::configure",
            "module::activate",
            "module::disable",
            "module::rollback",
            "module::quarantine",
            "module::verify_source",
            "module::approve_source",
            "module::run_conformance",
            "module::simulate_trust_change",
            "module::record_trust_review",
            "module::custom_future_operation"
        ] {
            #expect(actionIds.contains(required))
        }
        #expect(!actionIds.contains("worker::disconnect"))
        #expect(projection.actions.first { $0.functionId == "module::activate" }?.approvalRequired == true)
    }

    @Test("engine console loads validates and refreshes generated surfaces through ui primitives")
    func generatedSurfaceFlowUsesServerPrimitives() async throws {
        let client = FakeEngineConsoleCapabilityClient()
        let state = EngineConsoleState(capabilityClient: client, cache: ephemeralCache())
        let ref = UiSurfaceRefDTO(
            resourceId: "res-ui",
            versionId: "ver-ui",
            kind: "ui_surface",
            lifecycle: "active",
            surfaceId: "surface",
            title: "Surface",
            purpose: "Inspect",
            catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: 1),
            expiresAt: "2100-01-01T00:00:00Z",
            targets: [],
            actions: []
        )

        await state.inspectSurface(ref)
        #expect(state.selectedSurface?.resourceRef?.resourceId == "res-ui")

        await state.validateSurface(ref)
        #expect(state.surfaceError == nil)

        await state.refreshSelectedSurface()
        #expect(client.lastRefreshRequest?.surfaceResourceId == "res-ui")
        #expect(state.mutationState == .succeeded("Surface refreshed"))

        await state.submitSurfaceAction(
            UiActionSubmissionDTO(
                surfaceResourceId: "res-ui",
                surfaceVersionId: "ver-ui",
                actionId: "refresh-surface",
                userInput: [:],
                idempotencyKey: "client-generated"
            )
        )
        #expect(client.lastSubmission?.actionId == "refresh-surface")
        #expect(state.surfaceActionResult?.childInvocationId == "child")
    }

    private func ephemeralCache() -> EngineConsoleCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("EngineConsoleCache.json")
        return EngineConsoleCache(fileURL: url)
    }

    private func moduleAction(
        _ functionId: String,
        targetType: String,
        targetField: String,
        risk: String,
        approvalRequired: Bool
    ) -> AnyCodable {
        AnyCodable([
            "functionId": functionId,
            "targetType": targetType,
            "targetField": targetField,
            "target": NSNull(),
            "requiredRisk": risk,
            "approvalRequired": approvalRequired,
            "state": "available"
        ])
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
    var lastRefreshRequest: UiSurfaceRefreshRequestDTO?
    var lastSubmission: UiActionSubmissionDTO?
    var controlSnapshot = ControlSnapshotDTO(
        catalogRevision: 1,
        workers: [],
        capabilities: [],
        resourceTypes: [],
        activeGoals: [],
        invocations: [],
        grants: [],
        queues: [],
        leases: [],
        approvals: [],
        storage: nil,
        integrityWarnings: [],
        availableActions: []
    )

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

    func controlSnapshot(limit: Int) async throws -> ControlSnapshotDTO {
        controlSnapshot
    }

    func controlInspect(
        targetType: String,
        targetId: String,
        includeFullPayloads: Bool
    ) async throws -> ControlInspectDTO {
        ControlInspectDTO(targetType: targetType, targetId: targetId, graph: nil, availableActions: [])
    }

    func inspectUiSurface(surfaceResourceId: String) async throws -> UiSurfaceInspectResultDTO {
        UiSurfaceInspectResultDTO(
            inspection: AnyCodable(["resource": ["resourceId": surfaceResourceId]]),
            surface: UiSurfaceDTO(
                surfaceId: "surface",
                title: "Surface",
                purpose: "Inspect",
                catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: 1),
                layout: UiComponentDTO(id: "root", type: "Text", props: ["text": AnyCodable("hello")], children: nil),
                bindings: [],
                actions: [],
                redactionPolicy: ["mode": AnyCodable("redacted")],
                expiresAt: "2100-01-01T00:00:00Z",
                refreshPolicy: ["mode": AnyCodable("manual")]
            ),
            resourceRef: UiSurfaceRefDTO(
                resourceId: surfaceResourceId,
                versionId: "ver-ui",
                kind: "ui_surface",
                lifecycle: "active",
                surfaceId: "surface",
                title: "Surface",
                purpose: "Inspect",
                catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: 1),
                expiresAt: "2100-01-01T00:00:00Z",
                targets: [],
                actions: []
            ),
            validationState: "valid",
            bindings: [],
            actions: [],
            lineage: AnyCodable(["versionCount": 1])
        )
    }

    func validateUiSurface(surfaceResourceId: String) async throws -> UiSurfaceValidationDTO {
        UiSurfaceValidationDTO(surfaceResourceId: surfaceResourceId, validationState: "valid", diagnostics: [])
    }

    func surfaceForTarget(
        _ request: UiSurfaceForTargetRequestDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> UiSurfaceMutationResultDTO {
        UiSurfaceMutationResultDTO(
            surface: nil,
            resource: nil,
            version: nil,
            resourceRefs: [
                UiSurfaceRefDTO(
                    resourceId: "res-ui",
                    versionId: "ver-ui",
                    kind: "ui_surface",
                    lifecycle: "active",
                    surfaceId: "surface",
                    title: "Surface",
                    purpose: "Inspect",
                    catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: 1),
                    expiresAt: "2100-01-01T00:00:00Z",
                    targets: [],
                    actions: []
                )
            ]
        )
    }

    func refreshUiSurface(
        _ request: UiSurfaceRefreshRequestDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> UiSurfaceMutationResultDTO {
        lastRefreshRequest = request
        return try await surfaceForTarget(
            UiSurfaceForTargetRequestDTO(targetType: "worker", targetId: "demo"),
            idempotencyKey: idempotencyKey
        )
    }

    func submitUiAction(
        _ submission: UiActionSubmissionDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> UiActionResultDTO {
        lastSubmission = submission
        return UiActionResultDTO(
            surfaceResourceId: submission.surfaceResourceId,
            surfaceVersionId: submission.surfaceVersionId,
            actionId: submission.actionId,
            targetFunctionId: "ui::refresh_surface",
            childInvocationId: "child",
            result: AnyCodable(["ok": true])
        )
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
