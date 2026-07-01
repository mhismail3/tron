import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Agent Briefing View Model Tests")
struct AgentBriefingViewModelTests {
    @Test("Refresh reads scoped briefing from server projection")
    func refreshReadsScopedBriefing() async {
        let repository = MockAgentBriefingRepository()
        let viewModel = AgentBriefingViewModel()

        await viewModel.refresh(
            repository: repository,
            sessionId: "session-1",
            workspaceId: nil,
            connectionState: .connected
        )

        #expect(repository.agentBriefingOverviewCallCount == 1)
        #expect(repository.lastAgentBriefingSessionId == "session-1")
        #expect(repository.lastAgentBriefingWorkspaceId == nil)
        #expect(viewModel.state.overview?.operation == "agent_briefing_overview")
        #expect(viewModel.state.overview?.summary.activeWorkCount == 1)
        #expect(viewModel.isRefreshing == false)
    }

    @Test("Refresh degrades without exact scope")
    func refreshDegradesWithoutScope() async {
        let repository = MockAgentBriefingRepository()
        let viewModel = AgentBriefingViewModel()

        await viewModel.refresh(
            repository: repository,
            sessionId: nil,
            workspaceId: nil,
            connectionState: .connected
        )

        #expect(repository.agentBriefingOverviewCallCount == 0)
        if case .degraded(let message) = viewModel.state {
            #expect(message.contains("Open a session"))
        } else {
            Issue.record("Expected degraded briefing state")
        }
    }

    @Test("Disconnected to connected refresh replaces dashboard unavailable state")
    func disconnectedToConnectedRefreshLoadsServerBriefing() async {
        let repository = MockAgentBriefingRepository()
        let viewModel = AgentBriefingViewModel()

        await viewModel.refresh(
            repository: repository,
            sessionId: "session-1",
            workspaceId: nil,
            connectionState: .disconnected
        )

        #expect(repository.agentBriefingOverviewCallCount == 0)
        #expect(viewModel.state == .unavailable)

        await viewModel.refresh(
            repository: repository,
            sessionId: "session-1",
            workspaceId: nil,
            connectionState: .connected
        )

        #expect(repository.agentBriefingOverviewCallCount == 1)
        if case .loaded(let overview) = viewModel.state {
            #expect(overview.operation == "agent_briefing_overview")
            #expect(overview.summary.detail != "Connect to the server to read scoped activity.")
        } else {
            Issue.record("Expected connected refresh to load server briefing")
        }
    }
}

@MainActor
private final class MockAgentBriefingRepository: WorkerLifecycleRepository {
    var agentBriefing = AgentCockpitViewModelTests.agentBriefingOverview()
    var agentBriefingOverviewCallCount = 0
    var lastAgentBriefingSessionId: String?
    var lastAgentBriefingWorkspaceId: String?

    func overview(afterRevision: UInt64?) async throws -> CatalogWatchSnapshotDTO {
        CatalogWatchSnapshotDTO(changes: [], snapshot: nil, currentRevision: nil, nextRevision: nil, hasMore: false)
    }

    func listResources(kind: WorkerLifecycleResourceKind, lifecycle: String?, limit: UInt64) async throws -> ResourceListResultDTO {
        ResourceListResultDTO(resources: [])
    }

    func inspectResource(_ resourceId: String) async throws -> ResourceInspectResultDTO {
        ResourceInspectResultDTO(inspection: nil)
    }

    func moduleActivityOverview(limit: UInt64, sessionId: String?, workspaceId: String?) async throws -> ModuleActivityOverviewDTO {
        AgentCockpitViewModelTests.moduleActivityOverview()
    }

    func agentBriefingOverview(limit: UInt64, sessionId: String?, workspaceId: String?) async throws -> AgentBriefingOverviewDTO {
        agentBriefingOverviewCallCount += 1
        lastAgentBriefingSessionId = sessionId
        lastAgentBriefingWorkspaceId = workspaceId
        return agentBriefing
    }

    func proposePackageChange(manifest: [String: AnyCodable], summary: String, sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "proposed")
    }

    func installPackage(manifest: [String: AnyCodable], sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "installed")
    }

    func enablePackage(packageId: String, packageVersion: String, reason: String?, sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "enabled")
    }

    func disablePackage(packageId: String, packageVersion: String, reason: String?, sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "disabled")
    }

    func launchWorker(packageId: String, packageVersion: String, reason: String?, sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "launched")
    }

    func stopWorker(launchAttemptResourceId: String, reason: String?, sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "stopped")
    }

    func createCatalogDiscoveryReport(reason: String?, sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> CatalogDiscoveryReportResultDTO {
        CatalogDiscoveryReportResultDTO(status: "passed", reportResourceId: "catalog_discovery_report:test", streamCursor: nil, summary: nil, resourceRefs: nil)
    }

    func retirePackage(packageId: String, packageVersion: String, reason: String?, sessionId: String?, workspaceId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "retired")
    }
}
