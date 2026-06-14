import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Agent Cockpit View Model Tests")
struct AgentCockpitViewModelTests {
    @Test("Refresh loads catalog and lifecycle resources")
    func refreshLoadsCatalogAndResources() async {
        let repository = MockWorkerLifecycleRepository()
        repository.catalog = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
            currentRevision: 7,
            nextRevision: 8,
            hasMore: false
        )
        repository.resourcesByKind[.package] = [
            Self.resource(id: "worker_package:local.echo:1.0.0", kind: .package, lifecycle: "installed")
        ]
        repository.resourcesByKind[.uiSurface] = [
            Self.resource(id: "ui_surface:surface-1", kind: .uiSurface, lifecycle: "active")
        ]
        repository.inspections["ui_surface:surface-1"] = Self.surfaceInspection()
        let viewModel = AgentCockpitViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)

        #expect(repository.overviewCallCount == 1)
        #expect(repository.listedKinds.contains(.package))
        #expect(repository.listedKinds.contains(.uiSurface))
        #expect(viewModel.overview.currentRevision == 7)
        #expect(viewModel.overview.packages.first?.packageId == "local.echo")
        #expect(viewModel.overview.runtimeSurfaces.first?.surface.title == "Runtime")
        #expect(viewModel.overview.runtimeSurfaces.first?.resourceRef.kind == "ui_surface")
        #expect(viewModel.lastError == nil)
    }

    @Test("Install proposal fetches manifest from resource inspection")
    func installProposalFetchesManifestFromInspection() async throws {
        let repository = MockWorkerLifecycleRepository()
        repository.inspections["worker_package_proposal:local.echo:1.0.0:invocation-1"] = ResourceInspectResultDTO(
            inspection: EngineResourceInspectionDTO(
                resource: Self.resource(
                    id: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                    kind: .proposal,
                    lifecycle: "proposed"
                ),
                versions: [
                    EngineResourceVersionDTO(
                        versionId: "version-1",
                        resourceId: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                        parentVersionId: nil,
                        contentHash: nil,
                        state: "available",
                        payload: [
                            "manifest": AnyCodable([
                                "packageId": "local.echo",
                                "packageVersion": "1.0.0",
                                "futureField": ["kept": true]
                            ])
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
        let viewModel = AgentCockpitViewModel()
        let action = AgentCockpitAction(
            id: "install:worker_package_proposal:local.echo:1.0.0:invocation-1",
            kind: .installProposal,
            title: "Install",
            packageId: "local.echo",
            packageVersion: "1.0.0",
            proposalResourceId: "worker_package_proposal:local.echo:1.0.0:invocation-1",
            launchAttemptResourceId: nil,
            reason: "user approved package proposal",
            disabledReason: nil,
            isDestructive: false
        )

        let result = try await viewModel.perform(
            action,
            repository: repository,
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )

        #expect(result.status == "installed")
        #expect(repository.inspectCallIds == ["worker_package_proposal:local.echo:1.0.0:invocation-1"])
        #expect(repository.installedManifest?["packageId"]?.stringValue == "local.echo")
        #expect(repository.installedSessionId == "session-1")
        #expect(repository.installedWorkspaceId == "workspace-1")
    }

    @Test("Request confirmation ignores disabled actions")
    func requestConfirmationIgnoresDisabledActions() {
        let viewModel = AgentCockpitViewModel()
        let disabled = AgentCockpitAction(
            id: "launch:disabled",
            kind: .launchWorker,
            title: "Launch",
            packageId: "local.echo",
            packageVersion: "1.0.0",
            proposalResourceId: nil,
            launchAttemptResourceId: nil,
            reason: "test",
            disabledReason: "Package must be enabled before launch",
            isDestructive: false
        )

        viewModel.requestConfirmation(for: disabled)

        #expect(viewModel.pendingConfirmation == nil)
    }

    private static func resource(
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

    private static func surfaceInspection() -> ResourceInspectResultDTO {
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
}

@MainActor
private final class MockWorkerLifecycleRepository: WorkerLifecycleRepository {
    var catalog = CatalogWatchSnapshotDTO(
        changes: [],
        snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
        currentRevision: nil,
        nextRevision: nil,
        hasMore: false
    )
    var resourcesByKind: [WorkerLifecycleResourceKind: [EngineResourceDTO]] = [:]
    var inspections: [String: ResourceInspectResultDTO] = [:]

    var overviewCallCount = 0
    var listedKinds: [WorkerLifecycleResourceKind] = []
    var inspectCallIds: [String] = []
    var installedManifest: [String: AnyCodable]?
    var installedSessionId: String?
    var installedWorkspaceId: String?

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
        return ResourceListResultDTO(resources: resourcesByKind[kind] ?? [])
    }

    func inspectResource(_ resourceId: String) async throws -> ResourceInspectResultDTO {
        inspectCallIds.append(resourceId)
        return inspections[resourceId] ?? ResourceInspectResultDTO(inspection: nil)
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
