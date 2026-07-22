import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Research Suite Experience Tests")
struct ResearchSuiteViewModelTests {
    @Test("Only a supported primary suite entrypoint opens the native Research experience")
    func experienceRouting() {
        #expect(WorkerExperienceRoute.resolve(Self.worker(role: "coordinator", primary: true)) == .researchSuite)
        #expect(WorkerExperienceRoute.resolve(Self.worker(role: "search", primary: false)) == .genericConsole)
        #expect(WorkerExperienceRoute.resolve(Self.worker(role: "coordinator", primary: true, version: 2)) == .genericConsole)
    }

    @Test("Report decoding preserves claims, citations, sources, gaps, and specialist outcomes")
    func reportDecoding() throws {
        let report = try ResearchSuiteContract.decodeReport(AnyCodable(Self.reportOutput))

        #expect(report.reportId == "rr-20260722T130645Z-d480507abb3e")
        #expect(report.question == "Compare two APIs")
        #expect(report.supportedClaimCount == 1)
        #expect(report.citations.first?.excerpts == ["Official evidence"])
        #expect(report.sources.first?.domain == "example.com")
        #expect(report.evidenceGaps == ["No publication date"])
        #expect(report.limitations == ["Two sources only"])
        #expect(report.outcomes.map(\.role) == ["search", "sourceReview", "citation", "storage"])
        #expect(report.outcomes.first?.missingSecretBindings == ["provider-brave"])
    }

    @Test("Suite refresh reads each component and derives canonical reports from coordinator runs")
    func refreshReadsServerTruth() async {
        let workers = [
            Self.worker(role: "coordinator", primary: true),
            Self.worker(role: "search", primary: false),
            Self.worker(role: "source-review", primary: false),
            Self.worker(role: "citation", primary: false),
            Self.worker(role: "ignored", primary: false, experienceId: "other"),
        ]
        let repository = ResearchSuiteMockRepository(reportOutput: Self.reportOutput)
        let viewModel = ResearchSuiteViewModel()

        await viewModel.refresh(
            availableWorkers: workers,
            repository: repository,
            connectionState: .connected
        )

        #expect(viewModel.workers.map { $0.presentation?.componentRole } == [
            "coordinator", "search", "source-review", "citation",
        ])
        #expect(repository.runWorkerIds == [
            "research-coordinator", "research-search", "research-source-review", "research-citation",
        ])
        #expect(repository.inboxWorkerIds == repository.runWorkerIds)
        #expect(viewModel.reports.map(\.reportId) == ["rr-20260722T130645Z-d480507abb3e"])
        #expect(viewModel.healthyComponentCount == 4)
        #expect(viewModel.lastError == nil)
    }

    @Test("Malformed coordinator outputs are omitted without replacing valid durable history")
    func malformedReportsAreOmitted() async {
        let repository = ResearchSuiteMockRepository(reportOutput: ["schema": "not-a-report"])
        let viewModel = ResearchSuiteViewModel()

        await viewModel.refresh(
            availableWorkers: [Self.worker(role: "coordinator", primary: true)],
            repository: repository,
            connectionState: .connected
        )

        #expect(viewModel.runs.count == 1)
        #expect(viewModel.reports.isEmpty)
        #expect(viewModel.lastError == nil)
    }

    @Test("Malformed canonical report output is visible as a partial refresh error")
    func malformedCanonicalReportIsVisible() async {
        let repository = ResearchSuiteMockRepository(reportOutput: ["schema": "research.report.v1"])
        let viewModel = ResearchSuiteViewModel()

        await viewModel.refresh(
            availableWorkers: [Self.worker(role: "coordinator", primary: true)],
            repository: repository,
            connectionState: .connected
        )

        #expect(viewModel.reports.isEmpty)
        #expect(viewModel.lastError?.contains("Coordinator run run-1") == true)
    }

    private static func worker(
        role: String,
        primary: Bool,
        version: UInt32 = 1,
        experienceId: String = "research-suite"
    ) -> WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: role == "coordinator" ? "research-coordinator" : "research-\(role)",
            name: WorkerConsolePresentation.displayLabel(role),
            description: "Research \(role)",
            toolName: "worker_research_\(role)",
            runnerKind: role == "coordinator" ? "agent" : "command",
            activeVersion: "abcdef123456",
            enabled: true,
            retired: false,
            health: "healthy",
            triggerCount: 1,
            updatedAt: "2026-07-22T13:06:45Z",
            presentation: WorkerPresentationDTO(
                experienceId: experienceId,
                contractVersion: version,
                suiteId: experienceId,
                componentRole: role,
                primary: primary
            )
        )
    }

    fileprivate static let reportOutput: [String: Any] = [
        "schema": "research.report.v1",
        "reportId": "rr-20260722T130645Z-d480507abb3e",
        "status": "partial",
        "question": "Compare two APIs",
        "generatedAt": "2026-07-22T13:06:45Z",
        "answer": ["format": "report", "content": "A sourced comparison."],
        "claims": [[
            "claimId": "C1",
            "text": "The APIs use different headers.",
            "classification": "supported",
            "asserted": true,
            "citationIds": ["CIT-C1-S1"],
            "rationale": "The official docs identify the headers.",
            "uncertainty": [],
            "gaps": [],
        ]],
        "citations": [[
            "citationId": "CIT-C1-S1",
            "claimId": "C1",
            "sourceId": "S1",
            "title": "Official API docs",
            "url": "https://example.com/docs",
            "excerpts": [["evidenceId": "S1-E1", "text": "Official evidence"]],
        ]],
        "sourceManifest": [[
            "sourceId": "S1",
            "title": "Official API docs",
            "url": "https://example.com/docs",
            "domain": "example.com",
            "publisher": "Example",
            "accessedAt": "2026-07-22T13:00:00Z",
        ]],
        "contradictions": [],
        "evidenceGaps": ["No publication date"],
        "limitations": ["Two sources only"],
        "specialistOutcomes": [
            "search": [
                "called": true,
                "status": "unavailable",
                "errors": [],
                "resultCount": 0,
                "missingSecretBindings": ["provider-brave"],
            ],
            "sourceReview": [
                "called": true,
                "status": "complete",
                "errors": [],
                "sourceCount": 1,
                "evidenceCount": 1,
            ],
            "citation": [
                "called": true,
                "status": "complete",
                "errors": [],
                "claimCount": 1,
                "supportedClaimCount": 1,
            ],
            "storage": [
                "called": true,
                "status": "complete",
                "saved": true,
                "verified": true,
            ],
        ],
        "storage": [
            "saved": true,
            "verified": true,
            "reportId": "rr-20260722T130645Z-d480507abb3e",
            "relativeReportPath": "reports/rr-20260722T130645Z-d480507abb3e.json",
            "relativeIndexPath": "index.json",
        ],
    ]
}

@MainActor
private final class ResearchSuiteMockRepository: WorkerKernelRepository {
    let reportOutput: [String: Any]
    var runWorkerIds: [String] = []
    var inboxWorkerIds: [String] = []

    init(reportOutput: [String: Any]) {
        self.reportOutput = reportOutput
    }

    func workerRuns(workerId: String?, limit: UInt64) async throws -> WorkerRunsResultDTO {
        guard let workerId else { return WorkerRunsResultDTO(runs: []) }
        runWorkerIds.append(workerId)
        guard workerId == "research-coordinator" else { return WorkerRunsResultDTO(runs: []) }
        return WorkerRunsResultDTO(runs: [
            WorkerInvocationDTO(
                invocationId: "run-1",
                workerId: workerId,
                workerVersion: "abcdef123456",
                status: "completed",
                input: AnyCodable(["question": "Compare two APIs"]),
                output: AnyCodable(reportOutput),
                error: nil,
                idempotencyKey: "test",
                traceId: "trace-1",
                causalDepth: 0,
                triggerKind: "manual",
                agentSessionId: "session-1",
                attemptCount: 1,
                createdAt: "2026-07-22T13:00:00Z",
                startedAt: "2026-07-22T13:00:01Z",
                completedAt: "2026-07-22T13:06:45Z"
            ),
        ])
    }

    func workerInbox(workerId: String?, limit: UInt64) async throws -> WorkerInboxResultDTO {
        guard let workerId else { return WorkerInboxResultDTO(items: []) }
        inboxWorkerIds.append(workerId)
        return WorkerInboxResultDTO(items: [])
    }

    func engineSurfaceSnapshot(sessionId: String?, relevanceQuery: String?) async throws -> EngineIntrospectionSnapshotDTO { throw MockError.unused }
    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO { throw MockError.unused }
    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO { throw MockError.unused }
    func invokeWorker(workerId: String, input: AnyCodable, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerInvocationDTO { throw MockError.unused }
    func enqueueWorker(workerId: String, input: AnyCodable, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerInvocationDTO { throw MockError.unused }
    func cancelWorkerInvocation(invocationId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerInvocationDTO { throw MockError.unused }
    func setWorkerEnabled(_ enabled: Bool, workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerSummaryDTO { throw MockError.unused }
    func stopWorker(workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerSummaryDTO { throw MockError.unused }
    func rollbackWorker(workerId: String, version: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerRollbackResultDTO { throw MockError.unused }
    func retireWorker(workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerSummaryDTO { throw MockError.unused }
    func purgeWorker(workerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerPurgeResultDTO { throw MockError.unused }
    func setWorkersStopped(_ stopped: Bool, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerStopAllResultDTO { throw MockError.unused }
    func rotateWorkerWebhook(workerId: String, triggerId: String, idempotencyKey: EngineIdempotencyKey) async throws -> WorkerWebhookCredentialDTO { throw MockError.unused }
    func pollWorkerEvents(topic: String, cursor: EngineStreamCursor) async throws -> EngineStreamPage { throw MockError.unused }

    private enum MockError: Error { case unused }
}
