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
        repository.resourcesByKind[.catalogDiscoveryReport] = [
            Self.resource(id: "catalog_discovery_report:7:invocation-1", kind: .catalogDiscoveryReport, lifecycle: "passed")
        ]
        repository.capabilityVisibility = Self.capabilityCockpitOverview()
        repository.moduleActivity = Self.moduleActivityOverview()
        repository.inspections["ui_surface:surface-1"] = Self.surfaceInspection()
        let viewModel = AgentCockpitViewModel()

        await viewModel.refresh(
            repository: repository,
            sessionId: "test-session",
            workspaceId: "test-workspace",
            connectionState: .connected
        )

        #expect(repository.overviewCallCount == 1)
        #expect(repository.listedKinds.contains(.package))
        #expect(repository.listedKinds.contains(.uiSurface))
        #expect(repository.listedKinds.contains(.catalogDiscoveryReport))
        #expect(viewModel.overview.currentRevision == 7)
        #expect(viewModel.overview.packages.first?.packageId == "local.echo")
        #expect(viewModel.overview.discovery.reports.first?.resourceId == "catalog_discovery_report:7:invocation-1")
        #expect(viewModel.overview.runtimeSurfaces.first?.surface.title == "Runtime")
        #expect(viewModel.overview.runtimeSurfaces.first?.resourceRef.kind == "ui_surface")
        #expect(repository.moduleActivityOverviewCallCount == 1)
        #expect(repository.lastModuleActivitySessionId == "test-session")
        #expect(repository.lastModuleActivityWorkspaceId == "test-workspace")
        #expect(repository.capabilityCockpitOverviewCallCount == 1)
        #expect(repository.lastCapabilityCockpitSessionId == "test-session")
        #expect(repository.lastCapabilityCockpitWorkspaceId == "test-workspace")
        #expect(viewModel.overview.modularityOperations.contains { $0.name == "git_status" })
        #expect(viewModel.overview.discovery.operationCount == 2)
        #expect(viewModel.overview.moduleActivity?.summary.active == 1)
        #expect(viewModel.overview.activity.first?.title == "Active module runtime")
        #expect(viewModel.overview.activity.first?.status == "active")
        #expect(viewModel.lastError == nil)
    }

    @Test("Refresh failure preserves last overview and reports degraded status")
    func refreshFailurePreservesLastOverviewAndReportsDegradedStatus() async {
        let repository = MockWorkerLifecycleRepository()
        repository.catalog = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "local.echo::reply",
                        "ownerWorker": "local.echo",
                        "requestSchema": ["type": "object"],
                        "responseSchema": ["type": "object"]
                    ])
                ],
                workers: [
                    AnyCodable([
                        "id": "local.echo",
                        "kind": "External",
                        "lifecycle": "Ready"
                    ])
                ],
                triggers: [],
                triggerTypes: []
            ),
            currentRevision: 7,
            nextRevision: 8,
            hasMore: false
        )
        let viewModel = AgentCockpitViewModel()
        await viewModel.refresh(
            repository: repository,
            sessionId: "test-session",
            workspaceId: "test-workspace",
            connectionState: .connected
        )

        repository.listErrorsByKind[.package] = MockWorkerLifecycleError.failure("package resource refresh failed")
        await viewModel.refresh(
            repository: repository,
            sessionId: "test-session",
            workspaceId: "test-workspace",
            connectionState: .connected
        )

        #expect(viewModel.overview.status.kind == .degraded)
        #expect(viewModel.overview.status.title == "Refresh Failed")
        #expect(viewModel.overview.status.title != "Idle")
        #expect(viewModel.overview.currentRevision == 7)
        #expect(viewModel.overview.workers.first?.id == "local.echo")
        #expect(viewModel.lastError == "package resource refresh failed")
    }

    @Test("Verify catalog discovery creates conformance report and refreshes")
    func verifyCatalogDiscoveryCreatesReportAndRefreshes() async {
        let repository = MockWorkerLifecycleRepository()
        repository.catalog = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
            currentRevision: 7,
            nextRevision: 8,
            hasMore: false
        )
        let viewModel = AgentCockpitViewModel()

        await viewModel.verifyCatalogDiscovery(
            repository: repository,
            sessionId: "session-1",
            workspaceId: "workspace-1",
            connectionState: .connected
        )

        #expect(repository.createdCatalogReportReason == "engine cockpit catalog verification")
        #expect(repository.createdCatalogReportSessionId == "session-1")
        #expect(repository.createdCatalogReportWorkspaceId == "workspace-1")
        #expect(repository.overviewCallCount == 1)
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
}
