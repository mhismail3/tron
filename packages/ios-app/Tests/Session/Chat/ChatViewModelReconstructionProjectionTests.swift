import Foundation
import XCTest
@testable import TronMobile

extension ChatViewModelPaginationTests {
    func testReconnectPreservesStoppingWhileServerStillReportsActiveRun() async {
        let (viewModel, _) = makeViewModel()
        viewModel.agentPhase = .stopping

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [],
                hasMoreEvents: false,
                oldestEventId: nil,
                inFlight: InFlightState(
                    toolInvocations: [],
                    contentSequence: [],
                    streaming: nil
                )
            )
        )

        XCTAssertEqual(viewModel.agentPhase, .stopping)
    }

    func testReconnectReconstructionPreservesGeneratingToolChip() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [],
                hasMoreEvents: false,
                oldestEventId: nil,
                inFlight: InFlightState(
                    toolInvocations: [
                        CurrentTurnToolInvocation(
                            invocationId: "tool-generating-1",
                            arguments: nil,
                            status: "generating",
                            result: nil,
                            isError: nil,
                            startedAt: nil,
                            completedAt: nil,
                            streamingOutput: nil,
                            progressMessage: nil,
                            progressPercent: nil,
                            toolName: "process_run",
                            traceId: nil,
                            rootInvocationId: nil,
                            themeColor: nil,
                            presentationHints: nil
                        )
                    ],
                    contentSequence: [.toolRef(invocationId: "tool-generating-1")],
                    streaming: nil
                )
            )
        )

        XCTAssertEqual(viewModel.messages.count, 1)
        guard case .toolInvocation(let invocation) = viewModel.messages[0].content else {
            return XCTFail("Expected visible in-flight tool chip")
        }
        XCTAssertEqual(invocation.id, "tool-generating-1")
        XCTAssertEqual(invocation.status, .generating)
        XCTAssertTrue(viewModel.animationCoordinator.isToolInvocationVisible("tool-generating-1"))
    }

    func testReconnectInFlightProjectionDoesNotRegressPersistedToolSuccess() async {
        let (viewModel, _) = makeViewModel()
        let invocationId = "tool-terminal-success"

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [
                    rawToolStarted(id: "success-started", invocationId: invocationId, sequence: 1),
                    rawAssistantWithTool(id: "success-assistant", invocationId: invocationId, sequence: 2),
                    rawToolCompleted(id: "success-completed", invocationId: invocationId, sequence: 3)
                ],
                hasMoreEvents: false,
                oldestEventId: nil,
                inFlight: inFlightState(
                    currentTurnTool(invocationId: invocationId, status: "running")
                )
            )
        )

        let invocations = viewModel.messages.compactMap { message -> ToolInvocationData? in
            guard case .toolInvocation(let invocation) = message.content else { return nil }
            return invocation
        }
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.status, .success)
        XCTAssertEqual(invocations.first?.result, "done")
    }

    func testReconnectInFlightProjectionDoesNotRegressPersistedToolError() async {
        let (viewModel, _) = makeViewModel()
        let invocationId = "tool-terminal-error"

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [
                    rawToolStarted(id: "error-started", invocationId: invocationId, sequence: 1),
                    rawAssistantWithTool(id: "error-assistant", invocationId: invocationId, sequence: 2),
                    rawToolCompleted(
                        id: "error-completed",
                        invocationId: invocationId,
                        sequence: 3,
                        content: "failed",
                        isError: true
                    )
                ],
                hasMoreEvents: false,
                oldestEventId: nil,
                inFlight: inFlightState(
                    currentTurnTool(invocationId: invocationId, status: "running")
                )
            )
        )

        let invocations = viewModel.messages.compactMap { message -> ToolInvocationData? in
            guard case .toolInvocation(let invocation) = message.content else { return nil }
            return invocation
        }
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.status, .error)
        XCTAssertEqual(invocations.first?.result, "failed")
    }

    func testReconnectReconstructionRestoresToolProgressProjection() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [],
                hasMoreEvents: false,
                oldestEventId: nil,
                inFlight: InFlightState(
                    toolInvocations: [
                        CurrentTurnToolInvocation(
                            invocationId: "tool-progress-1",
                            arguments: nil,
                            status: "running",
                            result: nil,
                            isError: false,
                            startedAt: nil,
                            completedAt: nil,
                            streamingOutput: "partial output",
                            progressMessage: "Halfway",
                            progressPercent: 0.5,
                            toolName: "process_run",
                            traceId: nil,
                            rootInvocationId: nil,
                            themeColor: nil,
                            presentationHints: nil
                        )
                    ],
                    contentSequence: [.toolRef(invocationId: "tool-progress-1")],
                    streaming: nil
                )
            )
        )

        guard case .toolInvocation(let invocation) = viewModel.messages.first?.content else {
            return XCTFail("Expected reconstructed tool progress chip")
        }
        XCTAssertEqual(invocation.status, .running)
        XCTAssertEqual(invocation.progressMessage, "Halfway")
        XCTAssertEqual(invocation.progressPercent, 0.5)
    }

    func testReconnectReconstructionRestoresCompactionGateAndPill() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [],
                hasMoreEvents: false,
                oldestEventId: nil,
                isCompacting: true,
                compactionReason: "manual"
            )
        )

        XCTAssertTrue(viewModel.isCompacting)
        XCTAssertNotNil(viewModel.compactionInProgressMessageId)
        guard case .systemEvent(.compactionInProgress(let reason)) = viewModel.messages.last?.content else {
            return XCTFail("Expected reconstructed compaction-in-progress pill")
        }
        XCTAssertEqual(reason, "manual")
    }

    func testSuccessfulReconnectReconstructionClearsStalePrunedLiveBuffer() async {
        let (viewModel, _) = makeViewModel()
        viewModel.loadedReconstructionEvents = rawMessageEvents(range: 1...100)
        viewModel.prunedLiveMessages = (0..<20).map { makeMessage("stale live \($0)") }
        viewModel.hasInitiallyLoaded = true
        viewModel.displayedMessageCount = 100

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: rawMessageEvents(range: 1...120),
                hasMoreEvents: false,
                oldestEventId: "event-1"
            )
        )

        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
        XCTAssertEqual(viewModel.loadedReconstructionEvents.count, 120)
    }
}

extension ChatViewModelPaginationTests {
    // Shared construction and event fixtures for pagination and reconstruction tests.
    func makeViewModel() -> (ChatViewModel, PaginationTestSessionRepository) {
        let transport = MockEngineTransport()
        let sessions = PaginationTestSessionRepository()
        let services = ChatSessionServices(
            connection: PaginationTestConnectionRepository(),
            events: PaginationTestSessionEventRepository(),
            sessions: sessions,
            agent: AgentClient(transport: transport),
            models: DefaultModelRepository(modelClient: ModelClient(transport: transport)),
            messages: DefaultMessageRepository(messageClient: MessageClient(transport: transport)),
            workerKernel: DefaultWorkerKernelRepository(client: WorkerKernelClient(transport: transport))
        )
        return (ChatViewModel(services: services, sessionId: "test-session"), sessions)
    }

    func populateMessages(_ viewModel: ChatViewModel, count: Int) {
        for index in 0..<count {
            viewModel.appendToMessages(makeMessage("message \(index)"))
        }
    }

    func expectedDrainLoads(total: Int, batchSize: Int) -> [Int] {
        guard total > 0, batchSize > 0 else { return [] }
        var remaining = total
        var loads: [Int] = []
        while remaining > 0 {
            let load = min(batchSize, remaining)
            loads.append(load)
            remaining -= load
        }
        return loads
    }

    func makeMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text), timestamp: Date())
    }

    func textContent(_ message: ChatMessage?) -> String? {
        guard let message, case .text(let text) = message.content else {
            return nil
        }
        return text
    }

    func rawMessageEvents(range: ClosedRange<Int>) -> [RawEvent] {
        range.map { sequence in
            rawEvent(
                id: "event-\(sequence)",
                type: "message.user",
                content: "message \(sequence)",
                sequence: sequence
            )
        }
    }

    func reconstructResult(
        events: [RawEvent],
        hasMoreEvents: Bool,
        oldestEventId: String?,
        inFlight: InFlightState? = nil,
        isCompacting: Bool = false,
        compactionReason: String? = nil
    ) -> SessionReconstructResult {
        SessionReconstructResult(
            events: events,
            hasMoreEvents: hasMoreEvents,
            oldestEventId: oldestEventId,
            inFlight: inFlight,
            lastSequence: Int64(events.map(\.sequence).max() ?? 0),
            isRunning: inFlight != nil,
            isCompacting: isCompacting,
            compactionReason: compactionReason,
            agentPhase: inFlight == nil ? "idle" : "processing",
            metadata: ReconstructMetadata(
                model: nil,
                turnCount: nil,
                workingDirectory: nil,
                title: nil,
                tokenUsage: nil,
                totalCost: nil
            )
        )
    }

    func rawEvent(
        id: String,
        type: String,
        content: String,
        sequence: Int
    ) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: type,
            timestamp: "2026-01-01T00:00:00Z",
            sequence: sequence,
            payload: ["content": AnyCodable(content)]
        )
    }

    func chainEvent(
        id: String,
        sessionId: String,
        type: String,
        content: String,
        sequence: Int
    ) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "/test/workspace",
            type: type,
            timestamp: "2026-01-01T00:00:00Z",
            sequence: sequence,
            payload: ["content": AnyCodable(content)]
        )
    }

    func rawToolStarted(id: String, invocationId: String, sequence: Int) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: "tool.invocation.started",
            timestamp: "2026-01-01T00:00:00Z",
            sequence: sequence,
            payload: [
                "invocationId": AnyCodable(invocationId),
                "toolName": AnyCodable("process_run"),
                "arguments": AnyCodable(["command": "true"]),
                "turn": AnyCodable(1)
            ]
        )
    }

    func rawToolCompleted(
        id: String,
        invocationId: String,
        sequence: Int,
        content: String = "done",
        isError: Bool = false
    ) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: "tool.invocation.completed",
            timestamp: "2026-01-01T00:00:01Z",
            sequence: sequence,
            payload: [
                "invocationId": AnyCodable(invocationId),
                "toolName": AnyCodable("process_run"),
                "content": AnyCodable(content),
                "isError": AnyCodable(isError),
                "duration": AnyCodable(20)
            ]
        )
    }

    func rawAssistantWithTool(id: String, invocationId: String, sequence: Int) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: "message.assistant",
            timestamp: "2026-01-01T00:00:02Z",
            sequence: sequence,
            payload: [
                "content": AnyCodable([
                    [
                        "type": "tool_invocation",
                        "id": invocationId,
                        "name": "process_run",
                        "input": ["command": "true"]
                    ] as [String: Any]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "stopReason": AnyCodable("end_turn")
            ]
        )
    }

    func currentTurnTool(
        invocationId: String,
        status: String
    ) -> CurrentTurnToolInvocation {
        CurrentTurnToolInvocation(
            invocationId: invocationId,
            arguments: nil,
            status: status,
            result: nil,
            isError: false,
            startedAt: nil,
            completedAt: nil,
            streamingOutput: nil,
            progressMessage: nil,
            progressPercent: nil,
            toolName: "process_run",
            traceId: nil,
            rootInvocationId: nil,
            themeColor: nil,
            presentationHints: nil
        )
    }

    func inFlightState(
        _ toolInvocation: CurrentTurnToolInvocation
    ) -> InFlightState {
        InFlightState(
            toolInvocations: [toolInvocation],
            contentSequence: [.toolRef(invocationId: toolInvocation.invocationId)],
            streaming: nil
        )
    }
}

@MainActor
final class PaginationTestConnectionRepository: AppConnectionRepository {
    var connectionState: ConnectionState = .connected

    func connect() async {}
}

@MainActor
final class PaginationTestSessionEventRepository: SessionEventRepository {
    var currentSessionId: String?
    var currentModel: String = "claude-sonnet-4"
    var hasActiveSession: Bool = true

    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func ensureSessionEventSubscription(sessionId: String, workspaceId: String?) async throws {}
}

@MainActor
final class PaginationTestSessionRepository: NetworkSessionRepository {
    var reconstructCalls: [(sessionId: String, limit: Int?, beforeEventId: String?)] = []
    var reconstructHandler: ((String, Int?, String?) async throws -> SessionReconstructResult)?

    func create(
        workingDirectory: String,
        model: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionCreateResult {
        throw EngineConnectionError.invalidResponse
    }

    func list(
        workingDirectory: String?,
        limit: Int,
        cursor: String?,
        includeArchived: Bool
    ) async throws -> SessionListResult {
        throw EngineConnectionError.invalidResponse
    }

    func resume(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {}

    func reconstruct(sessionId: String, limit: Int?, beforeEventId: String?) async throws -> SessionReconstructResult {
        reconstructCalls.append((sessionId: sessionId, limit: limit, beforeEventId: beforeEventId))
        guard let reconstructHandler else {
            throw EngineConnectionError.invalidResponse
        }
        return try await reconstructHandler(sessionId, limit, beforeEventId)
    }

    func archive(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {}
    func unarchive(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {}

    func fork(
        sessionId: String,
        fromEventId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionForkResult {
        throw EngineConnectionError.invalidResponse
    }

    func getHistory(limit: Int) async throws -> [HistoryMessage] {
        []
    }
}
