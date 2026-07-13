import Foundation
@testable import TronMobile

extension AgentCockpitViewModelTests {
    nonisolated static func resource(
        id: String,
        kind: WorkerLifecycleResourceKind,
        lifecycle: String
    ) -> EngineResourceDTO {
        EngineResourceDTO(
            resourceId: id,
            kind: kind.rawValue,
            schemaId: nil,
            scope: AnyCodable("system"),
            ownerWorkerId: "worker",
            ownerActorId: "system",
            lifecycle: lifecycle,
            policy: nil,
            currentVersionId: "version-1",
            traceId: nil,
            createdByInvocationId: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    nonisolated static func surfaceInspection() -> ResourceInspectResultDTO {
        ResourceInspectResultDTO(
            inspection: EngineResourceInspectionDTO(
                resource: EngineResourceDTO(
                    resourceId: "ui_surface:surface-1",
                    kind: WorkerLifecycleResourceKind.uiSurface.rawValue,
                    schemaId: nil,
                    scope: AnyCodable("system"),
                    ownerWorkerId: "ui::runtime",
                    ownerActorId: "system",
                    lifecycle: "active",
                    policy: nil,
                    currentVersionId: "surface-version-1",
                    traceId: nil,
                    createdByInvocationId: nil,
                    createdAt: nil,
                    updatedAt: "2100-01-01T00:00:00Z"
                ),
                versions: [
                    EngineResourceVersionDTO(
                        versionId: "surface-version-1",
                        resourceId: "ui_surface:surface-1",
                        parentVersionId: nil,
                        contentHash: nil,
                        state: "available",
                        payload: [
                            "surfaceId": AnyCodable("surface-1"),
                            "title": AnyCodable("Runtime"),
                            "purpose": AnyCodable("cockpit"),
                            "schemaVersion": AnyCodable(1),
                            "layout": AnyCodable([
                                "type": "Text",
                                "props": ["text": "Live runtime surface"]
                            ]),
                            "actions": AnyCodable([]),
                            "expiresAt": AnyCodable("2100-01-01T00:00:00Z")
                        ],
                        locations: [],
                        createdByInvocationId: nil,
                        traceId: nil,
                        createdAt: nil
                    )
                ],
                outgoingLinks: [],
                incomingLinks: [],
                events: []
            )
        )
    }

    nonisolated static func moduleActivityOverview() -> ModuleActivityOverviewDTO {
        ModuleActivityOverviewDTO(
            schemaVersion: "tron.module_activity.overview.v1",
            operation: "module_activity_overview",
            summary: ModuleActivitySummaryDTO(
                total: 1,
                active: 1,
                waiting: 0,
                blocked: 0,
                ready: 0,
                recorded: 0,
                title: "Module work active",
                detail: "1 module runtime activities are active."
            ),
            timeline: [
                ModuleActivityItemDTO(
                    id: "module_runtime_state:version-1",
                    resourceId: "module_runtime_state:runtime-1",
                    resourceKind: "module_runtime_state",
                    status: "active",
                    state: "running",
                    title: "Active module runtime",
                    detail: "Server-owned projection",
                    authorityLabels: ["grant redacted", "derived runtime grant required"],
                    touchedResources: [
                        ModuleActivityResourceTouchDTO(label: "output refs", total: 1, truncated: false)
                    ],
                    rollbackStatus: ModuleActivityGateStatusDTO(label: "Rollback", state: "not_declared", blocked: false, waiting: false),
                    quarantineStatus: ModuleActivityGateStatusDTO(label: "Quarantine", state: "clear", blocked: false, waiting: false),
                    runtimeAuthorizationStatus: ModuleActivityGateStatusDTO(label: "Runtime authorization", state: "allowed", blocked: false, waiting: false),
                    updatedAt: "2026-06-20T12:00:00Z"
                )
            ],
            blocked: [],
            waiting: [],
            resources: [
                ModuleActivityResourceSummaryDTO(kind: "module_runtime_state", total: 1, active: 1, waiting: 0, blocked: 0)
            ],
            projection: ModuleActivityProjectionPolicyDTO(
                allowlist: "module_activity_cockpit_metadata_redacted_v1",
                serverOwnedTruth: true,
                metadataOnly: true,
                rawPayloadsReturned: false,
                rawCommandsReturned: false,
                rawLogsReturned: false,
                fileContentsReturned: false,
                absolutePathsReturned: false,
                grantIdsReturned: false,
                authorityIdsReturned: false,
                traceIdsReturned: false,
                invocationIdsReturned: false,
                tokenLikeMaterialReturned: false,
                boundedItems: true
            )
        )
    }

    nonisolated static func capabilityCockpitOverview() -> CapabilityCockpitOverviewDTO {
        CapabilityCockpitOverviewDTO(
            schemaVersion: "tron.capability_binding.cockpit_overview.v2",
            operation: "capability_binding_cockpit_overview",
            summary: CapabilityCockpitSummaryDTO(
                totalOperations: 2,
                returnedOperations: 2,
                operationListComplete: true,
                operationListTruncated: false,
                resourceScanComplete: true,
                resourceScanTruncated: false,
                kernelLocked: 1,
                governanceLocked: 0,
                recordPlane: 0,
                adapterReplaceable: 1,
                moduleOwned: 0,
                deferred: 0,
                bindingRequests: 1,
                bindingApproved: 0,
                bindingRejected: 1,
                activePolicies: 0,
                shadowRequests: 1,
                shadowRuns: 1,
                routeCandidates: 1,
                activeRoutes: 1,
                routeEvents: 2,
                routedInvocations: 1,
                failedClosedRoutes: 0,
                routeRollbacks: 0,
                rollbackAvailable: 1,
                title: "Capability ownership visible",
                detail: "2 operations, 1 binding request, 1 shadow request in this scope."
            ),
            operationList: CapabilityCockpitOperationListDTO(
                totalOperations: 2,
                returnedOperations: 2,
                requestedLimit: 2,
                complete: true,
                truncated: false,
                state: "complete",
                label: "Operation list complete",
                detail: "2 of 2 operations are returned."
            ),
            resourceScan: CapabilityCockpitResourceScanDTO(
                queries: 14,
                scannedResources: 3,
                appliedResources: 3,
                limitPerKindScope: 100,
                complete: true,
                truncated: false,
                truncatedQueries: 0,
                state: "complete",
                label: "Resource scan complete",
                detail: "3 resources scanned across 14 kind/scope scans; all bounded scans completed."
            ),
            families: [
                CapabilityCockpitFamilyDTO(
                    family: "git",
                    label: "Git",
                    operations: 1,
                    kernelLocked: 0,
                    governanceLocked: 0,
                    recordPlane: 0,
                    adapterReplaceable: 1,
                    moduleOwned: 0,
                    bindingActivity: 2,
                    shadowActivity: 2
                ),
                CapabilityCockpitFamilyDTO(
                    family: "core",
                    label: "Core",
                    operations: 1,
                    kernelLocked: 1,
                    governanceLocked: 0,
                    recordPlane: 0,
                    adapterReplaceable: 0,
                    moduleOwned: 0,
                    bindingActivity: 0,
                    shadowActivity: 0
                )
            ],
            routeStories: [
                CapabilityCockpitRouteStoryDTO(
                    kind: "active_route",
                    operation: "git_status",
                    title: "Inspect Git Status is using a governed replacement route",
                    detail: "1 routed invocation recorded. Rollback available and disable available.",
                    status: "active",
                    evidenceCount: 4,
                    lastUpdatedAt: "2026-06-27T12:01:00Z",
                    drillDownLabel: "Inspect route evidence"
                )
            ],
            operations: [
                CapabilityCockpitOperationDTO(
                    name: "git_status",
                    displayName: "Inspect Git Status",
                    description: "Inspects the current repository state without changing it.",
                    family: "git",
                    familyLabel: "Git",
                    capabilityPool: CapabilityCockpitPoolDTO(
                        surface: "agent_operation",
                        audience: "session_work",
                        replacementClass: "runtime_routable",
                        agentDefaultVisibility: "default_visible",
                        minimalityDecision: "module_candidate",
                        evolutionPath: "candidate validation, shadow evidence, approval, activation, and rollback"
                    ),
                    owner: CapabilityCockpitOwnerDTO(
                        label: "Built-in Git adapter",
                        detail: "A built-in adapter owns execution today and can be proposed for governed replacement later.",
                        source: "capability execute registry redacted ownership metadata plus scoped capability binding resources",
                        metadataSourceLabel: "Capability execute registry",
                        projectionSourceLabel: "Capability binding cockpit projection"
                    ),
                    status: CapabilityCockpitStatusDTO(
                        kind: "built_in_adapter",
                        label: "Built-in adapter",
                        detail: "Built-in execution can be shadowed or replaced only after governed evidence.",
                        builtIn: true,
                        moduleOwned: false,
                        locked: false
                    ),
                    replacement: CapabilityCockpitReplacementDTO(
                        canShadow: true,
                        canReplace: true,
                        canExtend: true,
                        label: "Shadow or replace after review",
                        detail: "Future modules can request shadow or replacement with exact authority, parity evidence, and rollback/disable metadata. Area: Git.",
                        target: CapabilityCockpitReplacementTargetDTO(
                            label: "Governed Git adapter",
                            detail: "Any future target must satisfy exact authority, parity evidence, bounded provider-safe refs, replay/idempotency proof, and rollback/disable metadata."
                        ),
                        governanceBoundary: "capability binding policy"
                    ),
                    readiness: CapabilityCockpitReadinessDTO(
                        state: "needs_governance_review",
                        label: "Review needed",
                        detail: "At least one binding or shadow outcome in this scope needs governance review before any replacement conclusion is safe.",
                        nextActionLabel: "Inspect decisions",
                        nextActionDetail: "Use the recorded governance evidence; do not infer readiness from the operation class alone."
                    ),
                    binding: CapabilityCockpitBindingDTO(
                        requested: 1,
                        approved: 0,
                        rejected: 1,
                        activePolicies: 0,
                        failedReplacementAttempts: 1,
                        latestState: "rejected",
                        lastUpdatedAt: "2026-06-27T12:00:00Z",
                        detail: "1 binding decision rejected; no runtime routing changed."
                    ),
                    shadowTrial: CapabilityCockpitShadowTrialDTO(
                        requested: 1,
                        approved: 1,
                        rejected: 0,
                        runs: 1,
                        passed: 1,
                        failed: 0,
                        aborted: 0,
                        disabled: 0,
                        latestState: "passed",
                        lastUpdatedAt: "2026-06-27T12:00:00Z",
                        availableForThisOperation: true,
                        detail: "1 metadata-only shadow run recorded; candidate execution and routing stayed disabled."
                    ),
                    route: CapabilityCockpitRouteDTO(
                        candidates: 1,
                        bindings: 1,
                        activeRoutes: 1,
                        routeEvents: 2,
                        routedInvocations: 1,
                        failedClosed: 0,
                        disabled: 0,
                        rolledBack: 0,
                        rollbackRecords: 0,
                        rollbackAvailable: true,
                        disableAvailable: true,
                        latestState: "routed_invocation",
                        lastUpdatedAt: "2026-06-27T12:01:00Z",
                        state: "active",
                        label: "Active route",
                        detail: "A scoped projection route is active and recent invocations replayed accepted provider-safe shadow evidence."
                    ),
                    rollback: CapabilityCockpitRollbackDTO(
                        available: true,
                        disableAvailable: true,
                        abortAvailable: true,
                        boundary: "capability binding governance",
                        detail: "Rollback metadata is available for the recorded policy or shadow trial; live routing still has not changed."
                    )
                ),
                CapabilityCockpitOperationDTO(
                    name: "observe",
                    displayName: "Record Observation",
                    description: "Records text as an assistant-visible observation.",
                    family: "core",
                    familyLabel: "Core",
                    capabilityPool: CapabilityCockpitPoolDTO(
                        surface: "agent_operation",
                        audience: "kernel_evolution",
                        replacementClass: "kernel_evolution_only",
                        agentDefaultVisibility: "inspect_only",
                        minimalityDecision: "keep_core",
                        evolutionPath: "source-level candidate change, validation, adversarial review, approved integration, and rollback evidence"
                    ),
                    owner: CapabilityCockpitOwnerDTO(
                        label: "Engine kernel",
                        detail: "The engine kernel owns this operation and modules cannot take it over.",
                        source: "capability execute registry redacted ownership metadata plus scoped capability binding resources",
                        metadataSourceLabel: "Capability execute registry",
                        projectionSourceLabel: "Capability binding cockpit projection"
                    ),
                    status: CapabilityCockpitStatusDTO(
                        kind: "kernel_locked",
                        label: "Kernel locked",
                        detail: "Engine substrate; replacement is not available.",
                        builtIn: true,
                        moduleOwned: false,
                        locked: true
                    ),
                    replacement: CapabilityCockpitReplacementDTO(
                        canShadow: false,
                        canReplace: false,
                        canExtend: false,
                        label: "No replacement",
                        detail: "A future module may read safe projections, but it cannot replace this kernel responsibility. Area: Core.",
                        target: CapabilityCockpitReplacementTargetDTO(
                            label: "Engine-owned kernel responsibility",
                            detail: "The target remains engine-owned; cockpit clients must treat this as observe-only metadata."
                        ),
                        governanceBoundary: "capability binding policy"
                    ),
                    readiness: CapabilityCockpitReadinessDTO(
                        state: "locked",
                        label: "Engine-owned",
                        detail: "The server registry marks this operation as locked; replacement readiness is not available.",
                        nextActionLabel: "Observe only",
                        nextActionDetail: "Show current ownership and do not offer replacement affordances."
                    ),
                    binding: CapabilityCockpitBindingDTO(
                        requested: 0,
                        approved: 0,
                        rejected: 0,
                        activePolicies: 0,
                        failedReplacementAttempts: 0,
                        latestState: nil,
                        lastUpdatedAt: nil,
                        detail: "No binding requests have been recorded in this scope."
                    ),
                    shadowTrial: CapabilityCockpitShadowTrialDTO(
                        requested: 0,
                        approved: 0,
                        rejected: 0,
                        runs: 0,
                        passed: 0,
                        failed: 0,
                        aborted: 0,
                        disabled: 0,
                        latestState: nil,
                        lastUpdatedAt: nil,
                        availableForThisOperation: false,
                        detail: "No shadow trial is available for this operation in the current slice."
                    ),
                    rollback: CapabilityCockpitRollbackDTO(
                        available: false,
                        disableAvailable: false,
                        abortAvailable: false,
                        boundary: "capability binding governance",
                        detail: "Rollback is not applicable because replacement is not allowed for this locked operation."
                    )
                )
            ],
            scope: CapabilityCockpitScopeDTO(
                sessionScoped: true,
                workspaceScoped: true,
                exactScopeRequired: true,
                source: "trusted invocation causal context"
            ),
            projection: CapabilityCockpitProjectionPolicyDTO(
                allowlist: "capability_binding_cockpit_visibility_redacted_v1",
                serverOwnedTruth: true,
                projectionOnly: true,
                metadataOnly: true,
                autonomyBehaviorCreated: false,
                runtimeRoutingChanged: false,
                dispatchTableMutated: false,
                hotSwapPerformed: false,
                moduleActivated: false,
                moduleExecuted: false,
                rawResourceIdsReturned: false,
                rawLocalPathsReturned: false,
                rawEnvValuesReturned: false,
                rawSecretsReturned: false,
                rawCommandsReturned: false,
                rawLogsReturned: false,
                rawCodeReturned: false,
                rawFileContentsReturned: false,
                rawGrantIdsReturned: false,
                rawAuthorityIdsReturned: false,
                traceIdsReturned: false,
                invocationIdsReturned: false,
                tokenLikeMaterialReturned: false,
                hiddenChainOfThoughtReturned: false,
                boundedItems: true
            )
        )
    }

    nonisolated static func agentBriefingOverview() -> AgentBriefingOverviewDTO {
        AgentBriefingOverviewDTO(
            schemaVersion: "tron.agent_briefing.overview.v1",
            operation: "agent_briefing_overview",
            summary: AgentBriefingSummaryDTO(
                title: "Tron has active work",
                detail: "1 active, 0 waiting on review, 0 blocked, 1 total records.",
                activeWorkCount: 1,
                needsYouCount: 0,
                weakPointCount: 0,
                activityCount: 1,
                degraded: false
            ),
            sections: [
                AgentBriefingSectionDTO(
                    id: "active_work",
                    title: "Active work",
                    question: "What is currently in motion?",
                    narrative: "Active module runtime work is in progress.",
                    items: [
                        AgentBriefingItemDTO(
                            id: "briefing-item-1",
                            title: "Active module runtime",
                            detail: "Server-owned projection",
                            status: "active",
                            evidence: AgentBriefingEvidenceDTO(
                                label: "Evidence 1",
                                resourceKind: "module_runtime_state",
                                updatedAt: "2026-06-20T12:00:00Z",
                                providerSafe: true
                            )
                        )
                    ],
                    emptyState: "No active work is in progress.",
                    drilldownAvailable: true
                )
            ],
            scope: AgentBriefingScopeDTO(
                sessionScoped: true,
                workspaceScoped: false,
                exactScopeRequired: true,
                payloadScopeTrusted: false
            ),
            projection: AgentBriefingProjectionPolicyDTO(
                allowlist: "agent_briefing_metadata_redacted_v1",
                serverOwnedTruth: true,
                projectionOnly: true,
                autonomyBehaviorCreated: false,
                metadataOnly: true,
                rawPayloadsReturned: false,
                rawCommandsReturned: false,
                rawLogsReturned: false,
                promptBodiesReturned: false,
                fileContentsReturned: false,
                absolutePathsReturned: false,
                grantIdsReturned: false,
                authorityIdsReturned: false,
                traceIdsReturned: false,
                invocationIdsReturned: false,
                tokenLikeMaterialReturned: false,
                boundedItems: true,
                sourceProjection: "module_activity_overview"
            )
        )
    }
}

@MainActor
final class MockWorkerLifecycleRepository: WorkerLifecycleRepository {
    var catalog = CatalogWatchSnapshotDTO(
        changes: [],
        snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
        currentRevision: nil,
        nextRevision: nil,
        hasMore: false
    )
    var resourcesByKind: [WorkerLifecycleResourceKind: [EngineResourceDTO]] = [:]
    var listErrorsByKind: [WorkerLifecycleResourceKind: Error] = [:]
    var inspections: [String: ResourceInspectResultDTO] = [:]
    var moduleActivity = AgentCockpitViewModelTests.moduleActivityOverview()
    var capabilityVisibility = AgentCockpitViewModelTests.capabilityCockpitOverview()
    var agentBriefing = AgentCockpitViewModelTests.agentBriefingOverview()

    var overviewCallCount = 0
    var moduleActivityOverviewCallCount = 0
    var lastModuleActivitySessionId: String?
    var lastModuleActivityWorkspaceId: String?
    var capabilityCockpitOverviewCallCount = 0
    var lastCapabilityCockpitSessionId: String?
    var lastCapabilityCockpitWorkspaceId: String?
    var agentBriefingOverviewCallCount = 0
    var lastAgentBriefingSessionId: String?
    var lastAgentBriefingWorkspaceId: String?
    var listedKinds: [WorkerLifecycleResourceKind] = []
    var inspectCallIds: [String] = []
    var installedManifest: [String: AnyCodable]?
    var installedSessionId: String?
    var installedWorkspaceId: String?
    var createdCatalogReportReason: String?
    var createdCatalogReportSessionId: String?
    var createdCatalogReportWorkspaceId: String?

    func overview(afterRevision: UInt64?) async throws -> CatalogWatchSnapshotDTO {
        overviewCallCount += 1
        return catalog
    }

    func listResources(
        kind: WorkerLifecycleResourceKind,
        lifecycle: String?,
        limit: UInt64
    ) async throws -> ResourceListResultDTO {
        listedKinds.append(kind)
        if let error = listErrorsByKind[kind] {
            throw error
        }
        return ResourceListResultDTO(resources: resourcesByKind[kind] ?? [])
    }

    func inspectResource(_ resourceId: String) async throws -> ResourceInspectResultDTO {
        inspectCallIds.append(resourceId)
        return inspections[resourceId] ?? ResourceInspectResultDTO(inspection: nil)
    }

    func moduleActivityOverview(
        limit: UInt64,
        sessionId: String?,
        workspaceId: String?
    ) async throws -> ModuleActivityOverviewDTO {
        moduleActivityOverviewCallCount += 1
        lastModuleActivitySessionId = sessionId
        lastModuleActivityWorkspaceId = workspaceId
        return moduleActivity
    }

    func capabilityCockpitOverview(
        limit: UInt64,
        sessionId: String?,
        workspaceId: String?
    ) async throws -> CapabilityCockpitOverviewDTO {
        capabilityCockpitOverviewCallCount += 1
        lastCapabilityCockpitSessionId = sessionId
        lastCapabilityCockpitWorkspaceId = workspaceId
        return capabilityVisibility
    }

    func agentBriefingOverview(
        limit: UInt64,
        sessionId: String?,
        workspaceId: String?
    ) async throws -> AgentBriefingOverviewDTO {
        agentBriefingOverviewCallCount += 1
        lastAgentBriefingSessionId = sessionId
        lastAgentBriefingWorkspaceId = workspaceId
        return agentBriefing
    }

    func proposePackageChange(
        manifest: [String: AnyCodable],
        summary: String,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "proposed")
    }

    func installPackage(
        manifest: [String: AnyCodable],
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        installedManifest = manifest
        installedSessionId = sessionId
        installedWorkspaceId = workspaceId
        return WorkerLifecycleResultDTO(status: "installed")
    }

    func enablePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "enabled")
    }

    func disablePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "disabled")
    }

    func launchWorker(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "launched")
    }

    func stopWorker(
        launchAttemptResourceId: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "stopped")
    }

    func createCatalogDiscoveryReport(
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> CatalogDiscoveryReportResultDTO {
        createdCatalogReportReason = reason
        createdCatalogReportSessionId = sessionId
        createdCatalogReportWorkspaceId = workspaceId
        return CatalogDiscoveryReportResultDTO(
            status: "passed",
            reportResourceId: "catalog_discovery_report:7:invocation-1",
            streamCursor: 10,
            summary: nil,
            resourceRefs: nil
        )
    }

    func retirePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "retired")
    }
}

enum MockWorkerLifecycleError: LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case let .failure(message):
            return message
        }
    }
}
