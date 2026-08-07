import Observation
import XCTest
@testable import TronMobile

@MainActor
final class ChatViewModelObservationTests: XCTestCase {

    private func makeViewModel(
        connection: ChatViewModelObservationConnectionRepository
    ) -> ChatViewModel {
        let transport = MockEngineTransport()
        return ChatViewModel(
            services: ChatSessionServices(
                connection: connection,
                events: PaginationTestSessionEventRepository(),
                sessions: PaginationTestSessionRepository(),
                agent: AgentClient(transport: transport),
                models: DefaultModelRepository(modelClient: ModelClient(transport: transport)),
                messages: DefaultMessageRepository(messageClient: MessageClient(transport: transport)),
                workerKernel: DefaultWorkerKernelRepository(client: WorkerKernelClient(transport: transport))
            ),
            sessionId: "test-session"
        )
    }

    func testObserveLoopCancelsWhileWaitingForObservedChange() async {
        let probe = ChatViewModelObservationProbe()
        let observationInstalled = expectation(description: "observation installed")
        let taskCancelled = expectation(description: "task cancelled")
        var readCount = 0

        let task = ChatViewModel.observeLoop({
            readCount += 1
            if readCount == 2 {
                observationInstalled.fulfill()
            }
            return probe.value
        }) { _ in
            XCTFail("No value change was expected")
        }

        await fulfillment(of: [observationInstalled], timeout: 1.0)
        task.cancel()

        Task { @MainActor in
            await task.value
            taskCancelled.fulfill()
        }

        await fulfillment(of: [taskCancelled], timeout: 1.0)
    }

    func testDisconnectThenActiveReconstructionPreservesStopping() async {
        let connection = ChatViewModelObservationConnectionRepository()
        let viewModel = makeViewModel(connection: connection)
        for _ in 0..<10 { await Task.yield() }

        viewModel.agentPhase = .stopping
        connection.connectionState = .disconnected
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(viewModel.agentPhase, .stopping)

        await viewModel.processReconstructionResult(
            SessionReconstructResult(
                events: [],
                hasMoreEvents: false,
                oldestEventId: nil,
                inFlight: InFlightState(
                    toolInvocations: [],
                    contentSequence: [],
                    streaming: nil
                ),
                lastSequence: 0,
                isRunning: true,
                isCompacting: false,
                compactionReason: nil,
                agentPhase: "processing",
                metadata: ReconstructMetadata(
                    model: nil,
                    turnCount: nil,
                    workingDirectory: nil,
                    title: nil,
                    tokenUsage: nil,
                    totalCost: nil
                )
            )
        )

        XCTAssertEqual(viewModel.agentPhase, .stopping)
    }

    func testDisconnectPreservesStreamingUntilReconstructionCapturesSnapshot() async {
        let connection = ChatViewModelObservationConnectionRepository()
        let viewModel = makeViewModel(connection: connection)
        for _ in 0..<10 { await Task.yield() }

        let streamingMessageId = UUID()
        viewModel.streamingManager.onCreateStreamingMessage = { streamingMessageId }
        viewModel.streamingManager.handleTextDelta("partially rendered")
        viewModel.isCompacting = true

        connection.connectionState = .disconnected
        for _ in 0..<100 {
            guard viewModel.isCompacting else { break }
            await Task.yield()
        }

        XCTAssertFalse(viewModel.isCompacting, "proves the disconnect observer completed")
        XCTAssertEqual(viewModel.streamingManager.streamingMessageId, streamingMessageId)
        XCTAssertEqual(viewModel.streamingManager.streamingText, "partially rendered")
        XCTAssertNil(viewModel.streamingRecoverySnapshot)

        viewModel.cleanUpStreamingState()

        XCTAssertEqual(
            viewModel.streamingRecoverySnapshot,
            StreamingRecoverySnapshot(messageId: streamingMessageId, text: "partially rendered")
        )
        XCTAssertNil(viewModel.streamingManager.streamingMessageId)
    }
}

@Observable
final class ChatViewModelObservationProbe {
    var value = 0
}

@Observable
@MainActor
final class ChatViewModelObservationConnectionRepository: AppConnectionRepository {
    var connectionState: ConnectionState = .connected
    var continuityGeneration: UInt64 = 0

    func connect() async {}
}
