import Observation
import XCTest
@testable import TronMobile

@MainActor
final class ChatViewModelObservationTests: XCTestCase {

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
        let transport = MockEngineTransport()
        let connection = ChatViewModelObservationConnectionRepository()
        let viewModel = ChatViewModel(
            services: ChatSessionServices(
                connection: connection,
                events: PaginationTestSessionEventRepository(),
                sessions: PaginationTestSessionRepository(),
                agent: AgentClient(transport: transport),
                models: DefaultModelRepository(modelClient: ModelClient(transport: transport)),
                messages: DefaultMessageRepository(messageClient: MessageClient(transport: transport)),
                transcription: DefaultTranscriptionRepository(client: TranscriptionClient(transport: transport)),
                workerLifecycle: DefaultWorkerLifecycleRepository(client: WorkerLifecycleClient(transport: transport))
            ),
            sessionId: "test-session"
        )
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
                    capabilityInvocations: [],
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
}

@Observable
final class ChatViewModelObservationProbe {
    var value = 0
}

@Observable
@MainActor
final class ChatViewModelObservationConnectionRepository: AppConnectionRepository {
    var connectionState: ConnectionState = .connected

    func connect() async {}
}
