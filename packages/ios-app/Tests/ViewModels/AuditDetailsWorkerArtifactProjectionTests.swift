import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("AuditDetailsWorkerArtifactProjection")
struct AuditDetailsWorkerArtifactProjectionTests {
    @Test("worker-artifacts projection explains session-created capability evidence")
    func explainsSessionCreatedCapabilityEvidence() async throws {
        let client = FakeAuditDetailsCapabilityClient()
        client.registrySnapshotDTO = CapabilityRegistrySnapshotDTO(
            plugins: [],
            implementations: [
                CapabilityImplementationDTO(
                    implementationId: "impl.session.summary",
                    contractId: "session_summary::summarize",
                    pluginId: "plugin.session.summary",
                    workerId: "worker-session-summary",
                    functionId: "session_summary::summarize",
                    version: 1,
                    health: "healthy",
                    visibility: "session",
                    latencyClass: nil,
                    costClass: nil,
                    trustTier: "session_generated",
                    authorityRequirements: nil,
                    runtimeRequirements: nil,
                    schemaDigest: "sha256:summary",
                    catalogRevision: 41,
                    provenance: AnyCodable([
                        "sessionId": "session-worker-artifacts",
                        "createdBy": "agent"
                    ]),
                    conformanceState: "passed",
                    signatureStatus: "engine_issued",
                    updatedAt: nil
                )
            ],
            bindings: [],
            documents: [],
            programRuns: []
        )
        client.controlSnapshot = ControlSnapshotDTO(
            catalogRevision: 41,
            workers: [
                AnyCodable([
                    "workerId": "worker-session-summary",
                    "health": "healthy",
                    "lifecycle": "active"
                ])
            ],
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
            availableActions: [],
            uiSurfaceRefs: [
                UiSurfaceRefDTO(
                    resourceId: "ui-surface:session-summary",
                    versionId: "ui-surface-version:session-summary",
                    kind: "ui_surface",
                    lifecycle: "active",
                    surfaceId: "surface-session-summary",
                    title: "Session Summary Surface",
                    purpose: "Inspect session_summary::summarize",
                    catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: 1),
                    expiresAt: nil,
                    targets: [
                        UiBindingDTO(
                            targetType: "capability",
                            targetId: "session_summary::summarize",
                            role: "primary",
                            label: "Session summary"
                        )
                    ],
                    actions: [
                        UiActionSummaryDTO(
                            actionId: "invoke-capability",
                            label: "Invoke",
                            targetFunctionId: "session_summary::summarize",
                            requiredGrant: nil,
                            requiredRisk: "low",
                            targetRevision: 1,
                            expiresAt: nil
                        )
                    ]
                )
            ]
        )
        client.auditResult = CapabilityAuditQueryResultDTO(
            events: [
                CapabilityAuditEventDTO(
                    id: "audit-cleanup",
                    eventType: "worker.disconnected",
                    traceId: "trace-session-summary",
                    payload: nil,
                    payloadSummary: AnyCodable(["workerId": "worker-session-summary"]),
                    createdAt: nil,
                    redacted: true
                ),
                CapabilityAuditEventDTO(
                    id: "audit-repair",
                    eventType: "capability.auto_repaired",
                    traceId: "trace-session-summary",
                    payload: nil,
                    payloadSummary: AnyCodable([
                        "functionId": "session_summary::summarize",
                        "repair": "fixed schema mismatch"
                    ]),
                    createdAt: nil,
                    redacted: true
                ),
                CapabilityAuditEventDTO(
                    id: "audit-updated",
                    eventType: "capability.updated",
                    traceId: "trace-session-summary",
                    payload: nil,
                    payloadSummary: AnyCodable([
                        "functionId": "session_summary::summarize",
                        "version": 2
                    ]),
                    createdAt: nil,
                    redacted: true
                ),
                CapabilityAuditEventDTO(
                    id: "audit-failed",
                    eventType: "capability.test_failed",
                    traceId: "trace-session-summary",
                    payload: nil,
                    payloadSummary: AnyCodable([
                        "functionId": "session_summary::summarize",
                        "status": "failed"
                    ]),
                    createdAt: nil,
                    redacted: true
                ),
                CapabilityAuditEventDTO(
                    id: "audit-promoted",
                    eventType: "capability.promoted",
                    traceId: "trace-session-summary",
                    payload: nil,
                    payloadSummary: AnyCodable([
                        "functionId": "session_summary::summarize",
                        "visibility": "workspace"
                    ]),
                    createdAt: nil,
                    redacted: true
                ),
                CapabilityAuditEventDTO(
                    id: "audit-revoked",
                    eventType: "capability.revoked",
                    traceId: "trace-session-summary",
                    payload: nil,
                    payloadSummary: AnyCodable([
                        "functionId": "session_summary::summarize",
                        "grantId": "grant-session-summary"
                    ]),
                    createdAt: nil,
                    redacted: true
                ),
                CapabilityAuditEventDTO(
                    id: "audit-discarded",
                    eventType: "capability.discarded",
                    traceId: "trace-session-summary",
                    payload: nil,
                    payloadSummary: AnyCodable([
                        "functionId": "session_summary::summarize",
                        "path": "disposable_session_summary.py"
                    ]),
                    createdAt: nil,
                    redacted: true
                )
            ],
            redacted: true
        )
        client.programRunResult = CapabilityProgramRunQueryResultDTO(
            programRuns: [
                CapabilityProgramRunDTO(
                    programRunId: "program-run-session-summary",
                    parentInvocationId: "parent-session-summary",
                    rootInvocationId: "root-session-summary",
                    bindingDecisionId: nil,
                    status: "ok",
                    traceId: "trace-session-summary",
                    codeHash: "sha256:program",
                    argsHash: "sha256:args",
                    limits: nil,
                    allowedContracts: nil,
                    allowedImplementations: nil,
                    childInvocations: ["child-session-summary"],
                    selectedImplementations: nil,
                    approvalState: nil,
                    artifacts: nil,
                    logs: nil,
                    error: nil,
                    compensationAttempts: nil,
                    payloadSummary: AnyCodable([
                        "operation": [
                            "functionId": "session_summary::summarize",
                            "implementationId": "impl.session.summary"
                        ]
                    ]),
                    createdAt: nil,
                    updatedAt: nil,
                    redacted: true
                )
            ],
            redacted: true
        )
        let state = AuditDetailsState(capabilityClient: client, cache: ephemeralCache())

        await state.refresh()

        let projection = state.workerArtifactProjection
        let change = try #require(projection.changes.first)
        #expect(change.functionId == "session_summary::summarize")
        #expect(change.provenanceText == "session session-worker-artifacts")
        #expect(change.testText == "passed")
        #expect(change.generatedSurfaceIds == ["surface-session-summary"])
        #expect(change.promotionText == "session")
        #expect(change.cleanupText == "worker.disconnected")
        #expect(change.traceIds == ["trace-session-summary"])
        #expect(change.programRunIds == ["program-run-session-summary"])
        #expect(change.childInvocationIds == ["child-session-summary"])
        #expect(change.evidenceValues.contains("Generated UI surface-session-summary"))
        #expect(change.evidenceValues.contains("Trace trace-session-summary"))
        #expect(change.shelfTitle == "Session summary")
        #expect(change.shelfSubtitle == "Created by agent")
        #expect(change.historyLabels == [
            "Created",
            "Updated",
            "Auto-repaired",
            "Tested",
            "Failed",
            "Promoted",
            "Revoked",
            "Discarded",
            "Reused"
        ])
        #expect(!change.shelfTitle.contains("session_summary::summarize"))
        #expect(!change.shelfSubtitle.contains("worker-session-summary"))
    }

    @Test("worker-artifacts projection includes live catalog session functions")
    func includesLiveCatalogSessionFunctions() async throws {
        let client = FakeAuditDetailsCapabilityClient()
        client.registrySnapshotDTO = CapabilityRegistrySnapshotDTO(
            plugins: [],
            implementations: [],
            bindings: [],
            documents: [],
            programRuns: []
        )
        client.catalogSnapshotResult = CatalogWatchSnapshotDTO(
            changes: [
                CatalogChangeDTO(
                    id: "catalog-change-session-visual",
                    beforeRevision: 40,
                    afterRevision: 41,
                    kind: "function_registered",
                    subjectId: "created_by_agent::visual_echo",
                    subjectKind: "function",
                    changeClass: "availability",
                    visibility: "session",
                    sessionId: "session-visual",
                    workspaceId: "workspace-visual",
                    ownerWorker: "worker-visual",
                    timestamp: nil
                )
            ],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "created_by_agent::visual_echo",
                        "revision": 1,
                        "owner_worker": "worker-visual",
                        "visibility": "Session",
                        "health": "Healthy",
                        "provenance": [
                            "session_id": "session-visual",
                            "workspace_id": "workspace-visual"
                        ],
                        "metadata": [
                            "contractId": "created_by_agent::visual_echo",
                            "implementationId": "session_generated.created_by_agent.visual_echo",
                            "pluginId": "session_generated.worker-visual",
                            "trustTier": "session_generated",
                            "conformanceState": "healthy"
                        ]
                    ])
                ],
                workers: [
                    AnyCodable([
                        "id": "worker-visual",
                        "lifecycle": "Ready",
                        "visibility": "Session"
                    ])
                ],
                triggers: [],
                triggerTypes: []
            ),
            currentRevision: 41,
            nextRevision: 42,
            hasMore: false
        )
        client.controlSnapshot = ControlSnapshotDTO(
            catalogRevision: 41,
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
            availableActions: [],
            uiSurfaceRefs: [
                UiSurfaceRefDTO(
                    resourceId: "ui-surface-worker-artifacts-visual",
                    versionId: "ui-surface-version-worker-artifacts-visual",
                    kind: "ui_surface",
                    lifecycle: "active",
                    surfaceId: "surface-worker-artifacts-visual",
                    title: "Worker Artifacts Visual Surface",
                    purpose: "Inspect created_by_agent::visual_echo",
                    catalog: UiCatalogRefDTO(id: GeneratedUIRenderer.catalogId, revision: 1),
                    expiresAt: nil,
                    targets: [
                        UiBindingDTO(
                            targetType: "capability",
                            targetId: "created_by_agent::visual_echo",
                            role: "primary",
                            label: "Worker Artifacts visual"
                        )
                    ],
                    actions: []
                )
            ]
        )
        client.auditResult = CapabilityAuditQueryResultDTO(
            events: [
                CapabilityAuditEventDTO(
                    id: "audit-visual",
                    eventType: "capability.execute",
                    traceId: "trace-worker-artifacts-visual",
                    payload: nil,
                    payloadSummary: AnyCodable(["functionId": "created_by_agent::visual_echo"]),
                    createdAt: nil,
                    redacted: true
                )
            ],
            redacted: true
        )
        let state = AuditDetailsState(capabilityClient: client, cache: ephemeralCache())

        await state.refresh()

        let change = try #require(state.workerArtifactProjection.changes.first)
        #expect(change.functionId == "created_by_agent::visual_echo")
        #expect(change.implementationId == "session_generated.created_by_agent.visual_echo")
        #expect(change.workerId == "worker-visual")
        #expect(change.provenanceText == "session session-visual")
        #expect(change.testText == "healthy")
        #expect(change.generatedSurfaceIds == ["surface-worker-artifacts-visual"])
        #expect(change.traceIds == ["trace-worker-artifacts-visual"])
    }

    private func ephemeralCache() -> AuditDetailsCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("AuditDetailsCache.json")
        return AuditDetailsCache(fileURL: url)
    }
}
