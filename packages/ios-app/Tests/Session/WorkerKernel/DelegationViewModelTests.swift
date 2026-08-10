import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Delegation Experience Tests")
struct DelegationViewModelTests {
    @Test("Only the exact supported primary worker binds to the Delegation experience")
    func presentationBindingIsExact() {
        #expect(DelegationContract.primaryWorker(from: [Self.worker()])?.workerId == "general-delegate")
        #expect(WorkerExperienceRoute.resolve(Self.worker()) == .delegation)
        #expect(DelegationContract.primaryWorker(from: [Self.worker(version: 2)]) == nil)
        #expect(DelegationContract.primaryWorker(from: [Self.worker(primary: false)]) == nil)
        #expect(DelegationContract.primaryWorker(from: [Self.worker(workerId: "other")]) == nil)
        #expect(WorkerExperienceRoute.resolve(Self.worker(workerId: "other")) == .genericConsole)
    }

    @Test("Typed results preserve the deliverable, evidence, constraints, and unresolved work")
    func resultDecoding() throws {
        let result = try DelegationContract.decodeResult(AnyCodable(Self.resultOutput))

        #expect(result.status == "completed")
        #expect(result.summary == "Inspected the workspace.")
        #expect(result.deliverable.dictionaryValue?["fileCount"] as? Int == 3)
        #expect(result.artifacts.first?.pathOrURL == "/tmp/report.json")
        #expect(result.evidence.first?.kind == "filesystem_list")
        #expect(result.constraints.first?.observed == true)
        #expect(result.unresolvedItems.isEmpty)
    }

    @Test("Malformed canonical results are rejected rather than adopted as UI truth")
    func malformedCanonicalResultIsRejected() {
        #expect(throws: DelegationContractError.invalidResult("version is not 1")) {
            try DelegationContract.decodeResult(AnyCodable([
                "schema": "delegation.result.v1",
                "version": 2,
            ]))
        }
    }

    @Test("Refresh reads the worker contract, runs, inbox, model, and child linkage")
    func refreshReadsServerTruth() async {
        let repository = DelegationMockRepository()
        let viewModel = DelegationViewModel()

        await viewModel.refresh(
            availableWorkers: [Self.worker()],
            repository: repository,
            connectionState: .connected
        )

        #expect(repository.inspectedWorkerIds == ["general-delegate"])
        #expect(repository.runWorkerIds == ["general-delegate"])
        #expect(repository.inboxWorkerIds == ["general-delegate"])
        #expect(repository.inboxAttentionFilters == [true])
        #expect(viewModel.runnerModel == "openai/gpt-5.5")
        #expect(viewModel.runs.first?.agentSessionId == "child-session-1")
        #expect(viewModel.resultsByInvocation["run-1"]?.status == "completed")
        #expect(viewModel.completedRunCount == 1)
        #expect(viewModel.currentAttentionCount == 0)
        #expect(viewModel.lastError == nil)
    }

    @Test("Historical failed and cancelled runs do not become current attention")
    func historicalFailuresStayInAuditHistory() async {
        let repository = DelegationMockRepository(runs: [
            Self.run(id: "run-failed", status: "failed", output: nil),
            Self.run(id: "run-cancelled", status: "cancelled", output: nil),
        ])
        let viewModel = DelegationViewModel()

        await viewModel.refresh(
            availableWorkers: [Self.worker()],
            repository: repository,
            connectionState: .connected
        )

        #expect(Set(viewModel.runs.map(\.status)) == ["failed", "cancelled"])
        #expect(viewModel.currentAttentionCount == 0)
        #expect(viewModel.lastError == nil)
    }

    @Test("Current worker health remains actionable")
    func unhealthyWorkerCountsAsCurrentAttention() async {
        let repository = DelegationMockRepository()
        let viewModel = DelegationViewModel()

        await viewModel.refresh(
            availableWorkers: [Self.worker(health: "failed")],
            repository: repository,
            connectionState: .connected
        )

        #expect(viewModel.currentAttentionCount == 1)
    }

    @Test("Offline refresh preserves the last authoritative Delegation projection")
    func offlineRefreshPreservesProjection() async {
        let repository = DelegationMockRepository()
        let viewModel = DelegationViewModel()
        let workers = [Self.worker()]

        await viewModel.refresh(
            availableWorkers: workers,
            repository: repository,
            connectionState: .connected
        )
        await viewModel.refresh(
            availableWorkers: [],
            repository: repository,
            connectionState: .disconnected
        )

        #expect(viewModel.worker == workers[0])
        #expect(viewModel.runs.count == 1)
        #expect(viewModel.lastError == nil)
        #expect(!viewModel.isLoading)
    }

    @Test("Submission builds the public contract and uses durable enqueue")
    func submitUsesDurableEnqueue() async {
        let repository = DelegationMockRepository()
        let viewModel = DelegationViewModel()
        await viewModel.refresh(
            availableWorkers: [Self.worker()],
            repository: repository,
            connectionState: .connected
        )
        viewModel.task = "Inspect the two paths"
        viewModel.deliverableDescription = "Return a count"
        viewModel.context = "Treat both paths as read-only."
        viewModel.filePaths = "/tmp/a\n/tmp/b\n/tmp/a"
        viewModel.constraints = "Do not modify files.\nCite inspected paths."
        viewModel.deadline = "2026-07-23T00:00:00Z"
        viewModel.budget = "high"
        viewModel.deliverableSchema = #"{"type":"object","required":["count"],"properties":{"count":{"type":"integer"}}}"#

        let succeeded = await viewModel.submit(
            repository: repository,
            connectionState: .connected,
            availableWorkers: [Self.worker()]
        )

        #expect(succeeded)
        #expect(repository.enqueuedInputs.count == 1)
        let input = repository.enqueuedInputs[0]
        #expect(input["task"] as? String == "Inspect the two paths")
        #expect(input["filePaths"] as? [String] == ["/tmp/a", "/tmp/b"])
        #expect(input["constraints"] as? [String] == ["Do not modify files.", "Cite inspected paths."])
        #expect(input["budget"] as? String == "high")
        #expect(AnyCodable(input["deliverable"]).dictionaryValue?["schema"] != nil)
        #expect(viewModel.lastSubmittedInvocationId == "run-enqueued-1")
    }

    @Test("Cancellation and retry target one durable invocation")
    func cancelAndRetryAreInvocationScoped() async {
        let repository = DelegationMockRepository()
        let viewModel = DelegationViewModel()
        await viewModel.refresh(
            availableWorkers: [Self.worker()],
            repository: repository,
            connectionState: .connected
        )
        let active = Self.run(id: "run-active", status: "running", output: nil)

        await viewModel.cancel(
            active,
            repository: repository,
            connectionState: .connected,
            availableWorkers: [Self.worker()]
        )
        await viewModel.retry(
            active,
            repository: repository,
            connectionState: .connected,
            availableWorkers: [Self.worker()]
        )

        #expect(repository.cancelledInvocationIds == ["run-active"])
        #expect(repository.enqueuedInputs.last?["task"] as? String == "Inspect workspace")
    }

    static func worker(
        workerId: String = "general-delegate",
        version: UInt32 = 1,
        primary: Bool = true,
        health: String = "healthy"
    ) -> WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: workerId,
            name: "General Delegate",
            description: "Executes one bounded delegated task.",
            toolName: "worker_general_delegate",
            runnerKind: "agent",
            activeVersion: "delegate-version-1",
            enabled: true,
            retired: false,
            health: health,
            triggerCount: 1,
            updatedAt: "2026-07-22T13:00:00Z",
            presentation: WorkerPresentationDTO(
                experienceId: "general-delegate",
                contractVersion: version,
                suiteId: "delegation",
                componentRole: "primary",
                primary: primary
            )
        )
    }

    static func run(
        id: String = "run-1",
        status: String = "completed",
        output: [String: Any]? = resultOutput
    ) -> WorkerInvocationDTO {
        WorkerInvocationDTO(
            invocationId: id,
            workerId: "general-delegate",
            workerVersion: "delegate-version-1",
            status: status,
            input: AnyCodable([
                "task": "Inspect workspace",
                "deliverable": ["description": "Return a file count"],
                "constraints": ["Do not modify files."],
            ]),
            output: output.map(AnyCodable.init),
            error: nil,
            idempotencyKey: "test-\(id)",
            traceId: "trace-\(id)",
            causalDepth: 1,
            triggerKind: "manual",
            originSessionId: "parent-session",
            agentSessionId: "child-session-1",
            attemptCount: 1,
            createdAt: "2026-07-22T13:00:00Z",
            startedAt: "2026-07-22T13:00:01Z",
            completedAt: status == "running" ? nil : "2026-07-22T13:00:20Z"
        )
    }

    static let resultOutput: [String: Any] = [
        "schema": "delegation.result.v1",
        "version": 1,
        "status": "completed",
        "summary": "Inspected the workspace.",
        "deliverable": ["fileCount": 3],
        "artifactReferences": [[
            "type": "json",
            "pathOrUrl": "/tmp/report.json",
            "description": "Generated report",
        ]],
        "evidence": [[
            "kind": "filesystem_list",
            "reference": "/tmp",
            "description": "Observed three files",
        ]],
        "constraintsObserved": [[
            "constraint": "Do not modify files.",
            "observed": true,
            "evidence": "Only read tools were used.",
        ]],
        "unresolvedItems": [],
    ]
}

@MainActor
private final class DelegationMockRepository: WorkerKernelRepository {
    var inspectedWorkerIds: [String] = []
    var runWorkerIds: [String] = []
    var inboxWorkerIds: [String] = []
    var inboxAttentionFilters: [Bool] = []
    var enqueuedInputs: [[String: Any]] = []
    var cancelledInvocationIds: [String] = []
    private var storedRuns: [WorkerInvocationDTO]

    init(runs: [WorkerInvocationDTO] = [DelegationViewModelTests.run()]) {
        storedRuns = runs
    }

    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO {
        inspectedWorkerIds.append(workerId)
        return WorkerInspectResultDTO(
            worker: DelegationViewModelTests.worker(),
            bundle: ["runner": AnyCodable(["kind": "agent", "model": "openai/gpt-5.5"])],
            versions: [],
            triggers: [],
            audit: [],
            versionDirectory: "/workers/general-delegate/v1"
        )
    }

    func workerRuns(
        workerId: String?,
        originSessionId: String?,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerRunsResultDTO {
        runWorkerIds.append(workerId ?? "all")
        return WorkerRunsResultDTO(runs: storedRuns)
    }

    func workerInbox(
        workerId: String?,
        limit: UInt64,
        offset: UInt64?,
        attentionOnly: Bool
    ) async throws -> WorkerInboxResultDTO {
        inboxWorkerIds.append(workerId ?? "all")
        inboxAttentionFilters.append(attentionOnly)
        return WorkerInboxResultDTO(items: [])
    }

    func scheduledWork(limit: UInt64, offset: UInt64?) async throws -> WorkerScheduledWorkResultDTO {
        throw MockError.unused
    }

    func dismissWorkerInboxItem(
        inboxId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInboxDismissResultDTO {
        throw MockError.unused
    }

    func enqueueWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        enqueuedInputs.append(input.dictionaryValue ?? [:])
        let run = WorkerInvocationDTO(
            invocationId: "run-enqueued-\(enqueuedInputs.count)",
            workerId: workerId,
            workerVersion: "delegate-version-1",
            status: "queued",
            input: input,
            output: nil,
            error: nil,
            idempotencyKey: idempotencyKey.rawValue,
            traceId: "trace-enqueued",
            causalDepth: 0,
            triggerKind: "manual",
            originSessionId: nil,
            agentSessionId: nil,
            attemptCount: 0,
            createdAt: "2026-07-22T14:00:00Z",
            startedAt: nil,
            completedAt: nil
        )
        storedRuns.insert(run, at: 0)
        return run
    }

    func cancelWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        cancelledInvocationIds.append(invocationId)
        return DelegationViewModelTests.run(id: invocationId, status: "cancelled", output: nil)
    }

    func engineSurfaceSnapshot(sessionId: String?, relevanceQuery: String?) async throws -> EngineIntrospectionSnapshotDTO { throw MockError.unused }
    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO { throw MockError.unused }
    func invokeWorker(workerId: String, input: AnyCodable, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerInvocationDTO { throw MockError.unused }
    func setWorkerEnabled(_ enabled: Bool, workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerSummaryDTO { throw MockError.unused }
    func stopWorker(workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerSummaryDTO { throw MockError.unused }
    func rollbackWorker(workerId: String, version: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerRollbackResultDTO { throw MockError.unused }
    func retireWorker(workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerSummaryDTO { throw MockError.unused }
    func purgeWorker(workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerPurgeResultDTO { throw MockError.unused }
    func setWorkersStopped(_ stopped: Bool, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerStopAllResultDTO { throw MockError.unused }
    func rotateWorkerWebhook(workerId: String, triggerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerWebhookCredentialDTO { throw MockError.unused }
    func ensureWorkerEventSubscriptions() async throws {}

    private enum MockError: Error { case unused }
}
