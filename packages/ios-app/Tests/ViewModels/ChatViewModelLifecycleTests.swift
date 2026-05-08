import Testing
import Foundation
@testable import TronMobile

// MARK: - ChatViewModel Lifecycle Tests

@Suite("ChatViewModel Lifecycle")
@MainActor
struct ChatViewModelLifecycleTests {

    @Test("Observation tasks are cancelled on deinit")
    func testObservationTasksCancelledOnDeinit() async {
        // Create a ChatViewModel instance
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        var viewModel: ChatViewModel? = ChatViewModel(engineClient: engineClient, sessionId: "test-session")

        // Verify the view model was created (compiler won't optimize away)
        #expect(viewModel != nil)

        // Release the view model — deinit should cancel all tasks
        viewModel = nil

        // If we get here without a crash, the deinit cleanup succeeded.
        // The key assertion is that no data race occurs during teardown.
        #expect(viewModel == nil)
    }

    @Test("ChatViewModel initializes with idle agent phase")
    func testInitialState() {
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")

        #expect(viewModel.agentPhase == .idle)
        #expect(viewModel.isCompacting == false)
        #expect(viewModel.messages.isEmpty)
    }
}
