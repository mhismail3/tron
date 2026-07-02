import XCTest
@testable import TronMobile

@MainActor
final class ChatViewModelPaginationTests: XCTestCase {

    func testTopDetentAutoloadLoadsFromPrunedBufferFirst() async {
        let (viewModel, _) = makeViewModel()
        populateMessages(viewModel, count: 250)
        viewModel.pruneOldMessagesIfNeeded()

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, ChatViewModel.additionalMessageBatchSize)
        XCTAssertEqual(viewModel.messages.count, 200)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 50)
    }

    func testTopDetentAutoloadContinuesToServerAfterPrunedBufferDrains() async {
        let (viewModel, sessions) = makeViewModel()
        populateMessages(viewModel, count: 210)
        viewModel.reconstructionOldestEventId = "cursor-1"
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.hasMoreMessages = true
        viewModel.pruneOldMessagesIfNeeded()

        sessions.reconstructHandler = { _, _, beforeEventId in
            XCTAssertEqual(beforeEventId, "cursor-1")
            return self.reconstructResult(
                events: [self.rawEvent(id: "event-user-1", type: "message.user", content: "older prompt", sequence: 1)],
                hasMoreEvents: false,
                oldestEventId: "cursor-0"
            )
        }

        let firstPrunedLoad = await viewModel.loadEarlierMessagesForTopDetent()
        let finalPrunedLoad = await viewModel.loadEarlierMessagesForTopDetent()
        let serverLoad = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(firstPrunedLoad, ChatViewModel.additionalMessageBatchSize)
        XCTAssertEqual(finalPrunedLoad, 10)
        XCTAssertEqual(serverLoad, 1)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-1"])
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "cursor-0")
        XCTAssertFalse(viewModel.hasMoreMessages)
    }

    func testTopDetentAutoloadLoadsHiddenReconstructedRowsAfterPrunedLiveBufferDrains() async {
        let (viewModel, sessions) = makeViewModel()
        let reconstructed = (0..<80).map { index in
            makeMessage("history \(index)")
        }
        viewModel.allReconstructedMessages = reconstructed
        viewModel.replaceAllMessages(with: Array(reconstructed.suffix(40)))
        viewModel.displayedMessageCount = 40

        for index in 0..<170 {
            viewModel.appendToMessages(makeMessage("live \(index)"))
        }

        viewModel.reconstructionOldestEventId = "cursor-history"
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.recomputeHasMoreMessages()
        viewModel.pruneOldMessagesIfNeeded()

        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 110)
        XCTAssertEqual(viewModel.displayedMessageCount, 40)

        let firstPrunedLoad = await viewModel.loadEarlierMessagesForTopDetent()
        let finalPrunedLoad = await viewModel.loadEarlierMessagesForTopDetent()
        let inMemoryLoad = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(firstPrunedLoad, ChatViewModel.additionalMessageBatchSize)
        XCTAssertEqual(finalPrunedLoad, 10)
        XCTAssertEqual(inMemoryLoad, 40)
        XCTAssertEqual(sessions.reconstructCalls.count, 0)
        XCTAssertEqual(viewModel.messages.first?.id, reconstructed.first?.id)
        XCTAssertTrue(viewModel.hasMoreMessages)
    }

    func testTopDetentAutoloadLoadsFromInMemoryReconstruction() async {
        let (viewModel, _) = makeViewModel()
        let reconstructed = (0..<150).map { index in
            makeMessage("history \(index)")
        }
        viewModel.allReconstructedMessages = reconstructed
        viewModel.replaceAllMessages(with: Array(reconstructed.suffix(50)))
        viewModel.displayedMessageCount = 50
        viewModel.hasMoreMessages = true

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 100)
        XCTAssertEqual(viewModel.messages.count, 150)
        XCTAssertEqual(viewModel.messages.first?.id, reconstructed.first?.id)
    }

    func testTopDetentAutoloadDuplicateLoadGuard() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.isLoadingMoreMessages = true

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 0)
        XCTAssertEqual(sessions.reconstructCalls.count, 0)
    }

    func testTopDetentAutoloadAdvancesPastEmptyServerPages() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.reconstructionOldestEventId = "cursor-2"

        sessions.reconstructHandler = { _, _, beforeEventId in
            if beforeEventId == "cursor-2" {
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-1")
            }
            return self.reconstructResult(
                events: [self.rawEvent(id: "event-user-1", type: "message.user", content: "older prompt", sequence: 1)],
                hasMoreEvents: false,
                oldestEventId: "cursor-0"
            )
        }

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 1)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-2", "cursor-1"])
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "cursor-0")
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertEqual(viewModel.messages.count, 1)
    }

    func testTopDetentAutoloadEmptyServerPageLimitStopsAdvertisingMoreHistory() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.reconstructionOldestEventId = "cursor-3"

        sessions.reconstructHandler = { _, _, beforeEventId in
            switch beforeEventId {
            case "cursor-3":
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-2")
            case "cursor-2":
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-1")
            case "cursor-1":
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-0")
            default:
                XCTFail("Unexpected cursor: \(String(describing: beforeEventId))")
                return self.reconstructResult(events: [], hasMoreEvents: false, oldestEventId: nil)
            }
        }

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 0)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-3", "cursor-2", "cursor-1"])
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "cursor-0")
        XCTAssertFalse(viewModel.hasOlderServerReconstructionPages)
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testTopDetentAutoloadServerErrorEmitsDedupedLocalError() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.reconstructionOldestEventId = "cursor-1"
        sessions.reconstructHandler = { _, _, _ in
            throw EngineConnectionError.invalidResponse
        }

        let firstLoaded = await viewModel.loadEarlierMessagesForTopDetent()
        let secondLoaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(firstLoaded, 0)
        XCTAssertEqual(secondLoaded, 0)
        XCTAssertEqual(viewModel.localNotificationIdsByDedupKey.keys.filter { $0 == "session.loadEarlier.failed" }.count, 1)
        let localErrorCount = viewModel.messages.filter {
            if case .localNotification = $0.content { return true }
            return false
        }.count
        XCTAssertEqual(localErrorCount, 1)
    }

    func testContextAwareServerPageKeepsCompletedCapabilityChip() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.reconstructionOldestEventId = "cursor-1"
        viewModel.loadedReconstructionEvents = [
            rawCapabilityCompleted(id: "event-completed", invocationId: "capability-1", sequence: 3)
        ]

        sessions.reconstructHandler = { _, _, _ in
            self.reconstructResult(
                events: [
                    self.rawCapabilityStarted(id: "event-started", invocationId: "capability-1", sequence: 1),
                    self.rawAssistantWithCapability(id: "event-assistant", invocationId: "capability-1", sequence: 2)
                ],
                hasMoreEvents: false,
                oldestEventId: "cursor-0"
            )
        }

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 1)
        guard case .capabilityInvocation(let invocation) = viewModel.messages.first?.content else {
            return XCTFail("Expected reconstructed capability chip")
        }
        XCTAssertEqual(invocation.id, "capability-1")
        XCTAssertEqual(invocation.status, .success)
        XCTAssertEqual(invocation.result, "done")
    }

    // MARK: - Helpers

    private func makeViewModel() -> (ChatViewModel, TestSessionRepository) {
        let transport = MockEngineTransport()
        let sessions = TestSessionRepository()
        let services = ChatSessionServices(
            connection: TestConnectionRepository(),
            events: TestSessionEventRepository(),
            sessions: sessions,
            agent: DefaultAgentRepository(agentClient: AgentClient(transport: transport)),
            models: DefaultModelRepository(modelClient: ModelClient(transport: transport)),
            messages: DefaultMessageRepository(messageClient: MessageClient(transport: transport)),
            transcription: DefaultTranscriptionRepository(client: TranscriptionClient(transport: transport)),
            workerLifecycle: DefaultWorkerLifecycleRepository(client: WorkerLifecycleClient(transport: transport))
        )
        return (ChatViewModel(services: services, sessionId: "test-session"), sessions)
    }

    private func populateMessages(_ viewModel: ChatViewModel, count: Int) {
        for index in 0..<count {
            viewModel.appendToMessages(makeMessage("message \(index)"))
        }
    }

    private func makeMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text), timestamp: Date())
    }

    private func reconstructResult(
        events: [RawEvent],
        hasMoreEvents: Bool,
        oldestEventId: String?
    ) -> SessionReconstructResult {
        SessionReconstructResult(
            events: events,
            hasMoreEvents: hasMoreEvents,
            oldestEventId: oldestEventId,
            inFlight: nil,
            lastSequence: Int64(events.map(\.sequence).max() ?? 0),
            isRunning: false,
            agentPhase: "idle",
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

    private func rawEvent(
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

    private func rawCapabilityStarted(id: String, invocationId: String, sequence: Int) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: "capability.invocation.started",
            timestamp: "2026-01-01T00:00:00Z",
            sequence: sequence,
            payload: [
                "invocationId": AnyCodable(invocationId),
                "modelPrimitiveName": AnyCodable("execute"),
                "arguments": AnyCodable(["command": "true"]),
                "turn": AnyCodable(1)
            ]
        )
    }

    private func rawCapabilityCompleted(id: String, invocationId: String, sequence: Int) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: "capability.invocation.completed",
            timestamp: "2026-01-01T00:00:01Z",
            sequence: sequence,
            payload: [
                "invocationId": AnyCodable(invocationId),
                "modelPrimitiveName": AnyCodable("execute"),
                "content": AnyCodable("done"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(20)
            ]
        )
    }

    private func rawAssistantWithCapability(id: String, invocationId: String, sequence: Int) -> RawEvent {
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
                        "type": "capability_invocation",
                        "id": invocationId,
                        "name": "execute",
                        "input": ["command": "true"]
                    ] as [String: Any]
                ]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "stopReason": AnyCodable("end_turn")
            ]
        )
    }
}

@MainActor
private final class TestConnectionRepository: AppConnectionRepository {
    var connectionState: ConnectionState = .connected
    var isConnected: Bool { true }

    func connect() async {}
    func disconnect() async {}
    func verifyConnection() async -> Bool { true }
    func manualRetry() async {}
    func setBackgroundState(_ inBackground: Bool) {}
}

@MainActor
private final class TestSessionEventRepository: SessionEventRepository {
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
private final class TestSessionRepository: NetworkSessionRepository {
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
        offset: Int,
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
