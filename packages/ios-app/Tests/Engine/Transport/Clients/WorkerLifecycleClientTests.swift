import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("WorkerLifecycleClient Tests")
struct WorkerLifecycleClientTests {
    @Test("Overview invokes catalog watch snapshot")
    func overviewInvokesCatalogWatchSnapshot() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "catalog::watch_snapshot")
            let request = try #require(payload as? CatalogWatchSnapshotRequestDTO)
            #expect(request.afterRevision == 12)
            #expect(request.limit == nil)
            return CatalogWatchSnapshotDTO(
                changes: [],
                snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
                currentRevision: 12,
                nextRevision: 13,
                hasMore: false
            )
        }

        let result = try await client.overview(afterRevision: 12)

        #expect(result.currentRevision == 12)
        #expect(transport.lastReadFunctionId?.rawValue == "catalog::watch_snapshot")
    }

    @Test("Package ref lifecycle writes use worker lifecycle functions")
    func packageRefWritesUseLifecycleFunctions() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)
        var seenFunctionIds: [String] = []

        transport.writeHandler = { functionId, payload, idempotencyKey, options in
            seenFunctionIds.append(functionId.rawValue)
            #expect(idempotencyKey.rawValue.contains("ios:user-action:"))
            #expect(options.context?.sessionId == "session-1")
            let request = try #require(payload as? WorkerLifecyclePackageRefRequestDTO)
            #expect(request.packageId == "package.alpha")
            #expect(request.packageVersion == "1.0.0")
            #expect(request.reason == "user approved")
            #expect(request.sessionId == "session-1")
            #expect(request.workspaceId == "workspace-1")
            return WorkerLifecycleResultDTO(status: "ok")
        }

        _ = try await client.enablePackage(
            packageId: "package.alpha",
            packageVersion: "1.0.0",
            reason: "user approved",
            sessionId: "session-1",
            workspaceId: "workspace-1",
            idempotencyKey: .userAction("worker.enable")
        )
        _ = try await client.disablePackage(
            packageId: "package.alpha",
            packageVersion: "1.0.0",
            reason: "user approved",
            sessionId: "session-1",
            workspaceId: "workspace-1",
            idempotencyKey: .userAction("worker.disable")
        )
        _ = try await client.launchWorker(
            packageId: "package.alpha",
            packageVersion: "1.0.0",
            reason: "user approved",
            sessionId: "session-1",
            workspaceId: "workspace-1",
            idempotencyKey: .userAction("worker.launch")
        )
        _ = try await client.retirePackage(
            packageId: "package.alpha",
            packageVersion: "1.0.0",
            reason: "user approved",
            sessionId: "session-1",
            workspaceId: "workspace-1",
            idempotencyKey: .userAction("worker.retire")
        )

        #expect(seenFunctionIds == [
            "worker_lifecycle::enable_package",
            "worker_lifecycle::disable_package",
            "worker_lifecycle::launch_worker",
            "worker_lifecycle::retire_package"
        ])
    }

    @Test("Stop worker uses launch attempt resource id")
    func stopWorkerUsesLaunchAttemptResourceId() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)

        transport.writeHandler = { functionId, payload, _, options in
            #expect(functionId.rawValue == "worker_lifecycle::stop_worker")
            #expect(options.context?.sessionId == "session-1")
            let request = try #require(payload as? WorkerLifecycleStopRequestDTO)
            #expect(request.launchAttemptResourceId == "worker_launch_attempt:alpha:123")
            #expect(request.reason == "pause work")
            return WorkerLifecycleResultDTO(status: "stopped")
        }

        let result = try await client.stopWorker(
            launchAttemptResourceId: "worker_launch_attempt:alpha:123",
            reason: "pause work",
            sessionId: "session-1",
            workspaceId: nil,
            idempotencyKey: .userAction("worker.stop")
        )

        #expect(result.status == "stopped")
    }

    @Test("Lifecycle resources use resource primitives")
    func lifecycleResourcesUseResourcePrimitives() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)
        var seenFunctionIds: [String] = []

        transport.readHandler = { functionId, payload, _ in
            seenFunctionIds.append(functionId.rawValue)
            switch functionId.rawValue {
            case "resource::list":
                let request = try #require(payload as? ResourceListRequestDTO)
                #expect(request.kind == "worker_package_proposal")
                #expect(request.limit == 50)
                return ResourceListResultDTO(resources: [
                    EngineResourceDTO(
                        resourceId: "worker_package_proposal:alpha:1.0.0:invocation-1",
                        kind: "worker_package_proposal",
                        schemaId: "tron.resource.worker_package_proposal.v1",
                        scope: AnyCodable("system"),
                        ownerWorkerId: "worker",
                        ownerActorId: "system",
                        lifecycle: "proposed",
                        policy: nil,
                        currentVersionId: "version-1",
                        traceId: nil,
                        createdByInvocationId: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                ])
            case "resource::inspect":
                let request = try #require(payload as? ResourceInspectRequestDTO)
                #expect(request.resourceId == "worker_package_proposal:alpha:1.0.0:invocation-1")
                return ResourceInspectResultDTO(inspection: nil)
            default:
                throw EngineConnectionError.invalidResponse
            }
        }

        let listed = try await client.listResources(kind: .proposal, limit: 50)
        _ = try await client.inspectResource("worker_package_proposal:alpha:1.0.0:invocation-1")

        #expect(listed.resources.first?.lifecycle == "proposed")
        #expect(seenFunctionIds == ["resource::list", "resource::inspect"])
    }

    @Test("Runtime surface resources use generic resource primitives")
    func runtimeSurfaceResourcesUseGenericResourcePrimitives() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "resource::list")
            let request = try #require(payload as? ResourceListRequestDTO)
            #expect(request.kind == "ui_surface")
            #expect(request.lifecycle == "active")
            #expect(request.limit == 25)
            return ResourceListResultDTO(resources: [])
        }

        _ = try await client.listResources(kind: .uiSurface, lifecycle: "active", limit: 25)
    }

    @Test("Capability cockpit overview invokes capability binding read with context")
    func capabilityCockpitOverviewInvokesCapabilityBindingReadWithContext() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)

        transport.readHandler = { functionId, payload, options in
            #expect(functionId.rawValue == "capability_binding::cockpit_overview")
            #expect(options.context?.sessionId == "session-1")
            #expect(options.context?.workspaceId == "workspace-1")
            let request = try #require(payload as? CapabilityCockpitOverviewRequestDTO)
            #expect(request.limit == 17)
            return CapabilityCockpitOverviewDTO(
                schemaVersion: "tron.capability_binding.cockpit_overview.v1",
                operation: "capability_binding_cockpit_overview",
                summary: CapabilityCockpitSummaryDTO(
                    totalOperations: 0,
                    returnedOperations: 0,
                    operationListComplete: true,
                    operationListTruncated: false,
                    resourceScanComplete: true,
                    resourceScanTruncated: false,
                    kernelLocked: 0,
                    governanceLocked: 0,
                    recordPlane: 0,
                    adapterReplaceable: 0,
                    moduleOwned: 0,
                    deferred: 0,
                    bindingRequests: 0,
                    bindingApproved: 0,
                    bindingRejected: 0,
                    activePolicies: 0,
                    shadowRequests: 0,
                    shadowRuns: 0,
                    rollbackAvailable: 0,
                    title: "Capability ownership visible",
                    detail: "No operations"
                ),
                operationList: CapabilityCockpitOperationListDTO(
                    totalOperations: 0,
                    returnedOperations: 0,
                    requestedLimit: 17,
                    complete: true,
                    truncated: false,
                    state: "complete",
                    label: "Operation list complete",
                    detail: "0 of 0 operations are returned."
                ),
                resourceScan: CapabilityCockpitResourceScanDTO(
                    queries: 0,
                    scannedResources: 0,
                    appliedResources: 0,
                    limitPerKindScope: 100,
                    complete: true,
                    truncated: false,
                    truncatedQueries: 0,
                    state: "complete",
                    label: "Resource scan complete",
                    detail: "No resources scanned."
                ),
                families: [],
                operations: [],
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

        let result = try await client.capabilityCockpitOverview(
            limit: 17,
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )

        #expect(result.operation == "capability_binding_cockpit_overview")
        #expect(result.projection.rawResourceIdsReturned == false)
    }

    @Test("Catalog discovery report write uses catalog discovery function")
    func catalogDiscoveryReportWriteUsesCatalogDiscoveryFunction() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)

        transport.writeHandler = { functionId, payload, idempotencyKey, options in
            #expect(functionId.rawValue == "catalog_discovery::conformance_report")
            #expect(idempotencyKey.rawValue.contains("ios:user-action:"))
            #expect(options.context?.sessionId == "session-1")
            #expect(options.context?.workspaceId == "workspace-1")
            let request = try #require(payload as? CatalogDiscoveryReportRequestDTO)
            #expect(request.reason == "engine cockpit catalog verification")
            #expect(request.includeProtectedCounts == true)
            #expect(request.sessionId == "session-1")
            #expect(request.workspaceId == "workspace-1")
            return CatalogDiscoveryReportResultDTO(
                status: "passed",
                reportResourceId: "catalog_discovery_report:7:invocation-1",
                streamCursor: 44,
                summary: ["functions": AnyCodable(["visible": 3])],
                resourceRefs: [
                    CatalogDiscoveryResourceRefDTO(
                        kind: "catalog_discovery_report",
                        resourceId: "catalog_discovery_report:7:invocation-1",
                        versionId: "version-1",
                        role: "catalog_discovery_report"
                    )
                ]
            )
        }

        let result = try await client.createCatalogDiscoveryReport(
            reason: "engine cockpit catalog verification",
            sessionId: "session-1",
            workspaceId: "workspace-1",
            idempotencyKey: .userAction("catalogDiscovery.report")
        )

        #expect(result.status == "passed")
        #expect(result.reportResourceId == "catalog_discovery_report:7:invocation-1")
        #expect(result.resourceRefs?.first?.kind == "catalog_discovery_report")
    }

    @Test("Manifest lifecycle writes keep manifest dynamic")
    func manifestWritesKeepManifestDynamic() async throws {
        let transport = connectedTransport()
        let client = WorkerLifecycleClient(transport: transport)
        var seenFunctionIds: [String] = []
        let manifest: [String: AnyCodable] = [
            "schemaVersion": AnyCodable("worker-package.v1"),
            "packageId": AnyCodable("package.alpha"),
            "futureField": AnyCodable(["nested": "kept"])
        ]

        transport.writeHandler = { functionId, payload, _, _ in
            seenFunctionIds.append(functionId.rawValue)
            switch functionId.rawValue {
            case "worker_lifecycle::propose_package_change":
                let request = try #require(payload as? WorkerLifecycleProposalRequestDTO)
                #expect(request.summary == "Review package alpha")
                #expect(request.manifest["futureField"]?.dictionaryValue?["nested"] as? String == "kept")
            case "worker_lifecycle::install_package":
                let request = try #require(payload as? WorkerLifecycleManifestRequestDTO)
                #expect(request.manifest["packageId"]?.stringValue == "package.alpha")
            default:
                Issue.record("Unexpected worker lifecycle manifest write \(functionId.rawValue)")
            }
            return WorkerLifecycleResultDTO(status: "accepted")
        }

        _ = try await client.proposePackageChange(
            manifest: manifest,
            summary: "Review package alpha",
            sessionId: nil,
            workspaceId: nil,
            idempotencyKey: .userAction("worker.propose")
        )
        _ = try await client.installPackage(
            manifest: manifest,
            sessionId: nil,
            workspaceId: nil,
            idempotencyKey: .userAction("worker.install")
        )

        #expect(seenFunctionIds == [
            "worker_lifecycle::propose_package_change",
            "worker_lifecycle::install_package"
        ])
    }

    private func connectedTransport() -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.connectionState = .connected
        return transport
    }
}
