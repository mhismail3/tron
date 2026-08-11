import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Worker Console View Model Tests")
struct WorkerConsoleViewModelTests {
    @Test("Refresh, inspect, stop, and disable use the worker kernel repository")
    func operationalFlowUsesWorkerKernelRepository() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(
            repository: repository,
            connectionState: .connected
        )
        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.healthyCount == 1)
        #expect(viewModel.enabledCount == 1)
        #expect(viewModel.unhealthyWorkerCount == 0)
        #expect(repository.snapshotSessionIds.count == 1)
        #expect(repository.snapshotSessionIds[0] == nil)
        #expect(viewModel.availableWorkerTools.map(\.workerId) == ["research"])
        #expect(viewModel.activityRuns.map(\.invocationId) == ["prior-run"])
        #expect(viewModel.activityResults.isEmpty)

        await viewModel.select("research", repository: repository)
        #expect(viewModel.inspection?.versions.first?.version == "v1")
        #expect(viewModel.runs.first?.invocationId == "prior-run")
        #expect(viewModel.attention.first?.inboxId == "inbox-1")
        #expect(repository.runLimits == [20, 20])
        #expect(repository.inboxLimits == [20])
        #expect(repository.inboxAttentionFilters == [false])
        #expect(viewModel.selectedResults.map(\.inboxId) == ["inbox-1"])

        await viewModel.stop(repository: repository, connectionState: .connected)
        #expect(repository.stoppedWorkerIds == ["research"])
        #expect(viewModel.selectedWorker?.enabled == true)

        await viewModel.setEnabled(false, repository: repository, connectionState: .connected)
        #expect(repository.enabledMutations == [false])
        #expect(viewModel.selectedWorker?.enabled == false)
    }

    @Test("Engine health count describes current worker state, not delivery attention")
    func engineHealthCountIsCurrentWorkerState() async {
        let repository = MockWorkerKernelRepository()
        repository.health = "failed"
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)
        await viewModel.refreshResults(repository: repository, connectionState: .connected)

        #expect(viewModel.unhealthyWorkerCount == 1)
        #expect(viewModel.activityResults.count == 1)

        repository.health = "healthy"
        await viewModel.refreshSummary(repository: repository, connectionState: .connected)

        #expect(viewModel.unhealthyWorkerCount == 0)
        #expect(viewModel.activityResults.count == 1)
    }

    @Test("Results use the complete durable inbox without loading execution history")
    func resultsLoadTheirOwnBoundedProjection() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshResults(repository: repository, connectionState: .connected)

        #expect(viewModel.activityResults.map(\.inboxId) == ["inbox-1"])
        #expect(repository.runLimits.isEmpty)
        #expect(repository.inboxAttentionFilters == [false])
    }

    @Test("Dashboard inventory separates active and retired workers")
    func dashboardInventorySeparatesRetiredWorkers() async {
        let repository = MockWorkerKernelRepository()
        repository.includeRetiredFixture = true
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)

        #expect(viewModel.workers.map(\.workerId) == ["retired-research", "research"])
        #expect(viewModel.activeWorkers.map(\.workerId) == ["research"])
        #expect(viewModel.retiredWorkers.map(\.workerId) == ["retired-research"])
        #expect(viewModel.enabledCount == 1)
    }

    @Test("Architecture metadata resolves beside canonical worker state")
    func architectureMetadataResolvesWithWorkerInspection() async throws {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        let architecture = try #require(viewModel.architecture(for: "research"))

        #expect(architecture.modelExposure == "direct")
        #expect(architecture.engineHooks == ["research_context"])
        #expect(viewModel.callers(of: "research").map(\.workerId) == ["research-coordinator"])

        await viewModel.select("research", repository: repository)
        #expect(viewModel.selectedWorkerArchitecture?.workerId == "research")
    }

    @Test("Declared engine and native client boundaries classify integrated workers")
    func integratedWorkerClassificationUsesBoundariesRatherThanExposure() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        #expect(viewModel.integratedWorkers.map(\.workerId) == ["research"])
        #expect(viewModel.generalWorkers.isEmpty)

        repository.researchEngineHooks = []
        repository.researchClientActions = ["speech_transcription"]
        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        #expect(viewModel.integratedWorkers.map(\.workerId) == ["research"])

        repository.researchClientActions = []
        repository.researchClientDeliveries = ["notification_delivery"]
        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        #expect(viewModel.integratedWorkers.map(\.workerId) == ["research"])

        repository.researchClientDeliveries = []
        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        #expect(viewModel.integratedWorkers.isEmpty)
        #expect(viewModel.generalWorkers.map(\.workerId) == ["research"])
    }

    @Test("Legacy agent roles form one nonduplicating review queue")
    func legacyAgentRolesAreSeparatedForReview() async {
        let repository = MockWorkerKernelRepository()
        repository.researchRoleReview = "needs_role_review"
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)

        #expect(viewModel.workersNeedingAgentRoleReview.map(\.workerId) == ["research"])
        #expect(viewModel.generalWorkers.isEmpty)
        #expect(viewModel.integratedWorkers.isEmpty)

        repository.researchRoleReview = "declared"
        await viewModel.refreshSummary(repository: repository, connectionState: .connected)

        #expect(viewModel.workersNeedingAgentRoleReview.isEmpty)
        #expect(viewModel.integratedWorkers.map(\.workerId) == ["research"])
    }

    @Test("Role review loads capability-gated queue and history pages without duplication")
    func roleReviewLoadsBoundedPages() async {
        let repository = MockWorkerKernelRepository()
        repository.supportsRoleReview = true
        repository.researchRoleReview = "needs_role_review"
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)

        #expect(viewModel.supportsAgentRoleReview)
        #expect(viewModel.roleReviewSnapshot?.reviewer.available == true)
        #expect(viewModel.roleReviewItems.map(\.workerId) == ["research"])
        #expect(viewModel.roleReviewSnapshot?.queueTotal == 2)
        #expect(viewModel.roleReviewSnapshot?.queueNextOffset == 1)
        #expect(viewModel.roleReviewProposals.map(\.proposalId) == ["role-proposal-current"])

        await viewModel.loadMoreRoleReviewQueue(
            repository: repository,
            connectionState: .connected
        )
        await viewModel.loadOlderRoleReviews(
            repository: repository,
            connectionState: .connected
        )

        #expect(viewModel.roleReviewItems.map(\.workerId) == ["research", "legacy-two"])
        #expect(viewModel.roleReviewProposals.map(\.proposalId) == [
            "role-proposal-current",
            "role-proposal-older",
        ])
        #expect(repository.roleReviewRequests.map { $0.queueOffset } == [nil, 1, nil])
        #expect(repository.roleReviewRequests.map { $0.offset } == [nil, nil, 1])
    }

    @Test("Role review starts and applies only server-authorized proposals")
    func roleReviewMutationsFollowAllowedActions() async {
        let repository = MockWorkerKernelRepository()
        repository.supportsRoleReview = true
        repository.researchRoleReview = "needs_role_review"
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        let item = viewModel.roleReviewItems[0]
        await viewModel.startRoleReview(
            for: item,
            repository: repository,
            connectionState: .connected
        )

        #expect(repository.roleReviewStartedWorkerIds == ["research"])
        #expect(viewModel.selectedRoleReviewProposal?.status == "proposed")
        #expect(viewModel.selectedRoleReviewProposal?.reviewerInvocationId == "reviewer-run-1")

        await viewModel.applySelectedRoleReview(
            repository: repository,
            connectionState: .connected
        )

        #expect(repository.roleReviewAppliedProposalIds == ["role-proposal-current"])
        #expect(viewModel.selectedRoleReviewProposal?.status == "applied")
        #expect(viewModel.workersNeedingAgentRoleReview.isEmpty)

        let deniedRepository = MockWorkerKernelRepository()
        deniedRepository.supportsRoleReview = true
        deniedRepository.researchRoleReview = "needs_role_review"
        deniedRepository.roleReviewActionsAllowed = false
        let deniedViewModel = WorkerConsoleViewModel()
        await deniedViewModel.refreshSummary(
            repository: deniedRepository,
            connectionState: .connected
        )
        await deniedViewModel.startRoleReview(
            for: deniedViewModel.roleReviewItems[0],
            repository: deniedRepository,
            connectionState: .connected
        )
        #expect(deniedRepository.roleReviewStartedWorkerIds.isEmpty)
    }

    @Test("Role review retains authoritative state offline and records rejection rationale")
    func roleReviewRetainsOfflineStateAndRejects() async throws {
        let repository = MockWorkerKernelRepository()
        repository.supportsRoleReview = true
        repository.researchRoleReview = "needs_role_review"
        repository.roleProposalExists = true
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        let proposal = try #require(viewModel.roleReviewItems.first?.proposal)
        await viewModel.inspectRoleReview(
            proposal,
            repository: repository,
            connectionState: .connected
        )
        #expect(repository.roleReviewInspectedProposalIds == ["role-proposal-current"])

        let readsBeforeOfflineRefresh = repository.roleReviewRequests.count
        await viewModel.refreshRoleReviews(
            repository: repository,
            connectionState: .disconnected
        )
        #expect(repository.roleReviewRequests.count == readsBeforeOfflineRefresh)
        #expect(viewModel.selectedRoleReviewProposal?.proposalId == "role-proposal-current")

        await viewModel.rejectSelectedRoleReview(
            reason: "Not a reusable responsibility.",
            repository: repository,
            connectionState: .connected
        )
        #expect(repository.roleReviewRejectedProposalIds == ["role-proposal-current"])
        #expect(repository.roleReviewRejectionReasons == ["Not a reusable responsibility."])
        #expect(viewModel.selectedRoleReviewProposal?.status == "rejected")
    }

    @Test("A retired worker exposes every retained version as a restore action")
    func retiredWorkerCanRestoreItsCurrentVersion() async throws {
        let repository = MockWorkerKernelRepository()
        repository.retired = true
        repository.enabled = false
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)
        await viewModel.select("research", repository: repository)
        let worker = try #require(viewModel.selectedWorker)
        let version = try #require(viewModel.inspection?.versions.first)

        #expect(WorkerVersionAction.resolve(worker: worker, version: version) == .restore)
        #expect(WorkerVersionAction.restore.title == "Restore")

        await viewModel.rollback(
            to: worker.activeVersion,
            repository: repository,
            connectionState: .connected
        )

        #expect(repository.rollbackVersions == ["v1"])
        #expect(viewModel.selectedWorker?.retired == false)
        let restoredWorker = try #require(viewModel.selectedWorker)
        #expect(WorkerVersionAction.resolve(worker: restoredWorker, version: version) == nil)
    }

    @Test("Worker monitoring subscribes at the live tail and refreshes only the sidebar summary")
    func monitoringUsesLiveInvalidationsWithoutHistoryReplay() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        let monitor = Task {
            await viewModel.monitorSummary(repository: repository, connectionState: .connected)
        }
        try? await Task.sleep(for: .milliseconds(20))
        NotificationCenter.default.post(name: .workerLifecycleProjectionInvalidated, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        monitor.cancel()
        await monitor.value

        #expect(repository.workerSubscriptionCount == 1)
        #expect(repository.snapshotSessionIds.count == 1)
        #expect(repository.runLimits.isEmpty)
        #expect(repository.inboxLimits.isEmpty)
        #expect(viewModel.monitoringError == nil)
    }

    @Test("Opening dashboard sections reuses summary and loads each bounded projection once")
    func sectionLoadingDoesNotRepeatTheEngineSnapshot() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.ensureSummaryLoaded(repository: repository, connectionState: .connected)
        await viewModel.ensureActivityLoaded(repository: repository, connectionState: .connected)
        await viewModel.ensureActivityLoaded(repository: repository, connectionState: .connected)
        await viewModel.ensureScheduledLoaded(repository: repository, connectionState: .connected)
        await viewModel.ensureScheduledLoaded(repository: repository, connectionState: .connected)
        await viewModel.ensureResultsLoaded(repository: repository, connectionState: .connected)
        await viewModel.ensureResultsLoaded(repository: repository, connectionState: .connected)

        #expect(repository.snapshotSessionIds.count == 1)
        #expect(repository.runLimits == [20])
        #expect(repository.scheduledRequests.count == 1)
        #expect(repository.scheduledRequests[0].limit == 50)
        #expect(repository.scheduledRequests[0].offset == nil)
        #expect(repository.inboxLimits == [20])
        #expect(viewModel.hasLoadedActivity)
        #expect(viewModel.hasLoadedScheduled)
        #expect(viewModel.hasLoadedResults)
    }

    @Test("Activity history loads every bounded page without duplicating runs")
    func activityHistoryPaginates() async {
        let repository = MockWorkerKernelRepository()
        repository.pagedActivity = true
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)
        #expect(viewModel.activityRuns.map(\.invocationId) == ["prior-run"])
        #expect(viewModel.activityRunsNextOffset == 1)

        await viewModel.loadOlderActivityRuns(repository: repository)
        #expect(viewModel.activityRuns.map(\.invocationId) == ["prior-run", "older-run"])
        #expect(viewModel.activityRunsNextOffset == nil)
        #expect(repository.runOffsets == [nil, 1])
    }

    @Test("Temporary disconnect preserves dashboard state until continuity refresh")
    func temporaryDisconnectPreservesDashboardProjection() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()
        await viewModel.refresh(repository: repository, connectionState: .connected)

        await viewModel.refresh(repository: repository, connectionState: .disconnected)

        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.primitiveToolCount == 0)
        #expect(viewModel.lastError == nil)

        viewModel.resetForServerChange()
        #expect(viewModel.workers.isEmpty)
        #expect(viewModel.engineSnapshot == nil)
    }

    @Test("An off-screen reconnect invalidates cached projections exactly once")
    func offscreenReconnectReconcilesSharedProjection() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()
        let ownerId = UUID()

        #expect(viewModel.reconcileServerProjection(EngineConnectionContinuity(
            state: .connected,
            generation: 1,
            ownerId: ownerId
        )) == false)
        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        #expect(viewModel.workers.map(\.workerId) == ["research"])

        #expect(viewModel.reconcileServerProjection(EngineConnectionContinuity(
            state: .disconnected,
            generation: 1,
            ownerId: ownerId
        )) == false)
        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.reconcileServerProjection(EngineConnectionContinuity(
            state: .connected,
            generation: 2,
            ownerId: ownerId
        )))
        #expect(viewModel.reconcileServerProjection(EngineConnectionContinuity(
            state: .connected,
            generation: 2,
            ownerId: ownerId
        )) == false)

        #expect(viewModel.reconcileServerProjection(EngineConnectionContinuity(
            state: .connected,
            generation: 0,
            ownerId: UUID()
        )) == false)
        #expect(viewModel.workers.isEmpty)
    }

    @Test("Transient transport error does not replace worker projection with an error")
    func transientRefreshErrorPreservesDashboardProjection() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()
        await viewModel.refresh(repository: repository, connectionState: .connected)

        repository.snapshotError = EngineConnectionError.notConnected
        await viewModel.refresh(repository: repository, connectionState: .connected)

        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.lastError == nil)
    }
}

@MainActor
private final class MockWorkerKernelRepository: WorkerKernelRepository {
    var enabled = true
    var retired = false
    var health = "healthy"
    var invokedWorkerIds: [String] = []
    var cancelledInvocationIds: [String] = []
    var stoppedWorkerIds: [String] = []
    var enabledMutations: [Bool] = []
    var rollbackVersions: [String] = []
    var lastInput: [String: Any]?
    var workerSubscriptionCount = 0
    var snapshotSessionIds: [String?] = []
    var runLimits: [UInt64] = []
    var inboxLimits: [UInt64] = []
    var inboxAttentionFilters: [Bool] = []
    var runOffsets: [UInt64?] = []
    var scheduledRequests: [(limit: UInt64, offset: UInt64?)] = []
    var pagedActivity = false
    var includeRetiredFixture = false
    var researchEngineHooks = ["research_context"]
    var researchClientActions: [String] = []
    var researchClientDeliveries: [String] = []
    var researchRoleReview = "ineligible"
    var supportsRoleReview = false
    var roleReviewActionsAllowed = true
    var roleProposalExists = false
    var roleProposalApplied = false
    var roleProposalRejected = false
    var roleReviewRequests: [(offset: UInt64?, queueOffset: UInt64?)] = []
    var roleReviewStartedWorkerIds: [String] = []
    var roleReviewInspectedProposalIds: [String] = []
    var roleReviewAppliedProposalIds: [String] = []
    var roleReviewRejectedProposalIds: [String] = []
    var roleReviewRejectionReasons: [String?] = []
    var snapshotError: Error?

    private var worker: WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: "research",
            name: "Research",
            description: "Recent research worker",
            toolName: "research",
            runnerKind: "command",
            activeVersion: "v1",
            enabled: enabled,
            retired: retired,
            health: enabled ? health : "disabled",
            triggerCount: 1,
            updatedAt: "2026-07-19T12:00:00Z",
            presentation: nil
        )
    }

    private var retiredWorker: WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: "retired-research",
            name: "Retired Research",
            description: "Retained research worker",
            toolName: "retired_research",
            runnerKind: "agent",
            activeVersion: "retired-v1",
            enabled: false,
            retired: true,
            health: "retired",
            triggerCount: 0,
            updatedAt: "2026-07-18T12:00:00Z",
            presentation: nil
        )
    }

    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String?
    ) async throws -> EngineIntrospectionSnapshotDTO {
        if let snapshotError { throw snapshotError }
        snapshotSessionIds.append(sessionId)
        return EngineIntrospectionSnapshotDTO(
            dispatchStopped: false,
            nativeCapabilities: supportsRoleReview ? ["agent_role_review.v1"] : nil,
            activeEngineHooks: [],
            activeClientActions: [],
            fixedTools: [],
            surface: AgentToolSurfaceDTO(
                catalogRevision: 42,
                surfaceHash: "surface-test",
                fixedToolCount: 27,
                projectedWorkerCount: 1,
                availableWorkerCount: 1,
                availableWorkers: [
                    AvailableWorkerToolDTO(
                        workerId: "research",
                        modelName: "worker_research",
                        functionId: "worker_kernel::dynamic_research",
                        functionRevision: 1,
                        workerVersion: "v1",
                        promoted: false,
                        projected: true,
                        selectionReason: "relevance",
                        relevanceScore: 1,
                        completedRuns: 1
                    )
                ]
            ),
            workers: includeRetiredFixture ? [retiredWorker, worker] : [worker],
            workerArchitecture: [
                WorkerArchitectureNodeDTO(
                    workerId: "research",
                    name: "Research",
                    description: "Recent research worker",
                    activeVersion: "v1",
                    health: "healthy",
                    modelExposure: "direct",
                    runnerKind: "command",
                    runnerModel: nil,
                    roleReview: researchRoleReview,
                    engineHooks: researchEngineHooks,
                    clientActions: researchClientActions,
                    clientDeliveries: researchClientDeliveries,
                    triggerKinds: ["schedule"],
                    calls: [],
                    presentation: WorkerArchitecturePresentationDTO(
                        suiteId: "research",
                        componentRole: "search",
                        primary: true
                    ),
                    provenance: []
                ),
                WorkerArchitectureNodeDTO(
                    workerId: "research-coordinator",
                    name: "Research Coordinator",
                    description: "Coordinates research",
                    activeVersion: "v1",
                    health: "healthy",
                    modelExposure: "direct",
                    runnerKind: "agent",
                    runnerModel: "test-model",
                    engineHooks: [],
                    clientActions: [],
                    clientDeliveries: [],
                    triggerKinds: [],
                    calls: [
                        WorkerArchitectureEdgeDTO(
                            kind: "agent_tool",
                            label: "Research",
                            targetWorkerId: "research",
                            responseOwner: nil
                        ),
                    ],
                    presentation: WorkerArchitecturePresentationDTO(
                        suiteId: "research",
                        componentRole: "coordinator",
                        primary: true
                    ),
                    provenance: []
                ),
            ]
        )
    }

    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO {
        WorkerListResultDTO(workers: [worker], stopAll: false)
    }

    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO {
        WorkerInspectResultDTO(
            worker: worker,
            bundle: [
                "inputSchema": AnyCodable(["type": "object"]),
                "provenance": AnyCodable(["source": "test"]),
            ],
            versions: [
                WorkerVersionDTO(
                    version: "v1",
                    contentHash: "v1",
                    createdAt: "2026-07-19T12:00:00Z"
                ),
            ],
            triggers: [],
            audit: [],
            versionDirectory: "/test/workers/research/versions/v1"
        )
    }

    func workerRuns(
        workerId: String?,
        originSessionId: String?,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerRunsResultDTO {
        runLimits.append(limit)
        runOffsets.append(offset)
        if pagedActivity, workerId == nil {
            if offset == nil {
                return WorkerRunsResultDTO(
                    runs: [invocation(id: "prior-run", output: ["prior": true])],
                    truncated: true,
                    nextOffset: 1
                )
            }
            return WorkerRunsResultDTO(
                runs: [invocation(id: "older-run", output: ["older": true])],
                truncated: false,
                nextOffset: nil
            )
        }
        return WorkerRunsResultDTO(runs: [invocation(id: "prior-run", output: ["prior": true])])
    }

    func workerInbox(
        workerId: String?,
        limit: UInt64,
        offset: UInt64?,
        attentionOnly: Bool
    ) async throws -> WorkerInboxResultDTO {
        inboxLimits.append(limit)
        inboxAttentionFilters.append(attentionOnly)
        return WorkerInboxResultDTO(items: [
            WorkerInboxItemDTO(
                inboxId: "inbox-1",
                invocationId: "prior-run",
                workerId: "research",
                severity: "info",
                result: AnyCodable(["prior": true]),
                contextAttached: false,
                createdAt: "2026-07-19T12:00:01Z",
                triggerKind: "schedule",
                hasInvocation: true,
                requiresAttention: true
            ),
        ])
    }

    func scheduledWork(
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerScheduledWorkResultDTO {
        scheduledRequests.append((limit, offset))
        return WorkerScheduledWorkResultDTO(
            items: [
                WorkerScheduledWorkItemDTO(
                    scheduledId: "schedule:research:nightly",
                    workerId: "research",
                    workerName: "Research",
                    kind: "recurring",
                    triggerId: "nightly",
                    invocationId: nil,
                    scheduledAt: "2026-08-11T07:00:00Z",
                    everySeconds: 86_400,
                    triggerKind: "schedule"
                ),
            ],
            truncated: false,
            nextOffset: nil
        )
    }

    func roleReviews(
        limit: UInt64,
        offset: UInt64?,
        queueLimit: UInt64,
        queueOffset: UInt64?
    ) async throws -> WorkerRoleReviewListDTO {
        roleReviewRequests.append((offset, queueOffset))
        let reviewer = WorkerRoleReviewerDTO(
            available: true,
            workerId: "role-reviewer",
            workerVersion: "review-v3",
            repairRequirement: nil
        )
        if queueOffset != nil {
            return WorkerRoleReviewListDTO(
                capability: "agent_role_review.v1",
                reviewer: reviewer,
                items: [roleReviewItem(workerId: "legacy-two", proposal: nil)],
                queueReturned: 1,
                queueTotal: 2,
                queueTruncated: false,
                queueNextOffset: nil,
                proposals: [],
                returned: 0,
                total: 2,
                nextOffset: nil
            )
        }
        if offset != nil {
            return WorkerRoleReviewListDTO(
                capability: "agent_role_review.v1",
                reviewer: reviewer,
                items: [roleReviewItem(workerId: "research", proposal: currentRoleProposal)],
                queueReturned: 1,
                queueTotal: 2,
                queueTruncated: true,
                queueNextOffset: 1,
                proposals: [roleProposal(id: "role-proposal-older", status: "rejected")],
                returned: 1,
                total: 2,
                nextOffset: nil
            )
        }
        let current = roleProposalExists || roleProposalApplied || roleProposalRejected
            ? currentRoleProposal
            : nil
        let items = roleProposalApplied || roleProposalRejected
            ? []
            : [roleReviewItem(workerId: "research", proposal: current)]
        return WorkerRoleReviewListDTO(
            capability: "agent_role_review.v1",
            reviewer: reviewer,
            items: items,
            queueReturned: UInt64(items.count),
            queueTotal: roleProposalApplied || roleProposalRejected ? 0 : 2,
            queueTruncated: !(roleProposalApplied || roleProposalRejected),
            queueNextOffset: roleProposalApplied || roleProposalRejected ? nil : 1,
            proposals: [currentRoleProposal],
            returned: 1,
            total: 2,
            nextOffset: 1
        )
    }

    func startRoleReview(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRoleReviewProposalDTO {
        roleReviewStartedWorkerIds.append(workerId)
        roleProposalExists = true
        return currentRoleProposal
    }

    func inspectRoleReview(_ proposalId: String) async throws -> WorkerRoleReviewProposalDTO {
        roleReviewInspectedProposalIds.append(proposalId)
        return currentRoleProposal
    }

    func applyRoleReview(
        proposalId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRoleReviewApplyResultDTO {
        roleReviewAppliedProposalIds.append(proposalId)
        roleProposalApplied = true
        researchRoleReview = "declared"
        return WorkerRoleReviewApplyResultDTO(
            proposal: currentRoleProposal,
            worker: worker
        )
    }

    func rejectRoleReview(
        proposalId: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRoleReviewProposalDTO {
        roleReviewRejectedProposalIds.append(proposalId)
        roleReviewRejectionReasons.append(reason)
        roleProposalRejected = true
        return currentRoleProposal
    }

    func dismissWorkerInboxItem(
        inboxId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInboxDismissResultDTO {
        WorkerInboxDismissResultDTO(
            inboxId: inboxId,
            disposition: "dismissed",
            resolvedAt: "2026-07-19T12:00:02Z"
        )
    }

    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        invokedWorkerIds.append(workerId)
        lastInput = input.value as? [String: Any]
        return invocation(id: "new-run", output: ["accepted": true])
    }

    func enqueueWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWorker(workerId: workerId, input: input, idempotencyKey: idempotencyKey)
    }

    func cancelWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        cancelledInvocationIds.append(invocationId)
        return invocation(id: invocationId, output: ["cancelled": true])
    }

    func setWorkerEnabled(
        _ enabled: Bool,
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        self.enabled = enabled
        enabledMutations.append(enabled)
        return worker
    }

    func stopWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        stoppedWorkerIds.append(workerId)
        return worker
    }

    func rollbackWorker(
        workerId: String,
        version: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRollbackResultDTO {
        rollbackVersions.append(version)
        retired = false
        enabled = true
        return WorkerRollbackResultDTO(worker: worker, webhooks: [])
    }

    func retireWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        worker
    }

    func purgeWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerPurgeResultDTO {
        WorkerPurgeResultDTO(
            workerId: workerId,
            purged: true,
            archivePath: "/test/backups/research.tar.zst",
            archiveSha256: String(repeating: "a", count: 64)
        )
    }

    func setWorkersStopped(
        _ stopped: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerStopAllResultDTO {
        WorkerStopAllResultDTO(stopped: stopped)
    }

    func rotateWorkerWebhook(
        workerId: String,
        triggerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerWebhookCredentialDTO {
        WorkerWebhookCredentialDTO(triggerId: triggerId, path: "/hook", token: "redacted-test-token")
    }

    func ensureWorkerEventSubscriptions() async throws {
        workerSubscriptionCount += 1
    }

    private func invocation(id: String, output: [String: Any]) -> WorkerInvocationDTO {
        WorkerInvocationDTO(
            invocationId: id,
            workerId: "research",
            workerVersion: "v1",
            status: "completed",
            input: AnyCodable(["query": "Tron"]),
            output: AnyCodable(output),
            error: nil,
            idempotencyKey: "test-key",
            traceId: "trace-1",
            causalDepth: 0,
            triggerKind: "manual",
            originSessionId: nil,
            agentSessionId: nil,
            attemptCount: 1,
            createdAt: "2026-07-19T12:00:00Z",
            startedAt: nil,
            completedAt: "2026-07-19T12:00:01Z"
        )
    }

    private var currentRoleProposal: WorkerRoleReviewProposalDTO {
        let status = roleProposalApplied ? "applied" : (roleProposalRejected ? "rejected" : "proposed")
        return roleProposal(id: "role-proposal-current", status: status)
    }

    private func roleProposal(id: String, status: String) -> WorkerRoleReviewProposalDTO {
        let mutable = status == "proposed"
        return WorkerRoleReviewProposalDTO(
            proposalId: id,
            schemaVersion: 1,
            proposalHash: "sha256:\(id)",
            targetWorkerId: "research",
            targetWorkerVersion: "v1",
            targetContentHash: "sha256:target",
            reviewerWorkerId: "role-reviewer",
            reviewerWorkerVersion: "review-v3",
            reviewerInvocationId: "reviewer-run-1",
            status: status,
            agentRole: AnyCodable([
                "status": "enabled",
                "displayName": "Research Specialist",
                "summary": "Coordinates bounded research.",
                "collaborationInstructions": "Return sourced research.",
                "resultMode": "natural",
            ]),
            rationale: "The runner has a reusable bounded responsibility.",
            rejectionReason: status == "rejected" ? "Not a reusable responsibility." : nil,
            createdAt: "2026-08-11T08:00:00Z",
            updatedAt: "2026-08-11T08:01:00Z",
            appliedAt: status == "applied" ? "2026-08-11T08:02:00Z" : nil,
            rejectedAt: status == "rejected" ? "2026-08-11T08:02:00Z" : nil,
            allowedActions: [
                WorkerRoleReviewActionDTO(action: "inspect", allowed: true, disabledReason: nil),
                WorkerRoleReviewActionDTO(
                    action: "apply",
                    allowed: mutable && roleReviewActionsAllowed,
                    disabledReason: roleReviewActionsAllowed ? nil : "Review authority is unavailable."
                ),
                WorkerRoleReviewActionDTO(
                    action: "reject",
                    allowed: mutable && roleReviewActionsAllowed,
                    disabledReason: roleReviewActionsAllowed ? nil : "Review authority is unavailable."
                ),
            ]
        )
    }

    private func roleReviewItem(
        workerId: String,
        proposal: WorkerRoleReviewProposalDTO?
    ) -> WorkerRoleReviewItemDTO {
        WorkerRoleReviewItemDTO(
            workerId: workerId,
            name: workerId == "research" ? "Research" : "Legacy Two",
            description: "Agent runner awaiting an explicit role decision",
            targetVersion: "v1",
            classification: "needs_role_review",
            proposal: proposal,
            allowedActions: proposal == nil ? [
                WorkerRoleReviewActionDTO(
                    action: "start_review",
                    allowed: roleReviewActionsAllowed,
                    disabledReason: roleReviewActionsAllowed ? nil : "A healthy reviewer is required."
                ),
            ] : [
                WorkerRoleReviewActionDTO(action: "inspect", allowed: true, disabledReason: nil),
            ]
        )
    }
}
