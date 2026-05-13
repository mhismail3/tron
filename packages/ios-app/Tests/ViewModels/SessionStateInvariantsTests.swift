import XCTest
@testable import TronMobile

/// Codify the per-session state invariants so future refactors can't
/// silently violate them:
///
/// 1. Each session gets a fresh ChatViewModel because ContentView
///    uses `.id(sessionId)` on the navigation destination. Constructing
///    two ChatViewModels with different sessionIds produces
///    independent state; there's no "carryover" from a prior session.
///
/// 2. `cleanUpStreamingState` — called during reconstruction, NOT
///    session switch — is narrowly scoped to in-flight-turn state.
///    User-facing composition state (inputBarState text, selected
///    skills, attachments) MUST survive a reconnect so the user
///    doesn't lose their work.
@MainActor
final class SessionStateInvariantsTests: XCTestCase {

    private var engineClient: EngineClient!

    override func setUp() async throws {
        engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
    }

    override func tearDown() async throws {
        engineClient = nil
    }

    private func makeViewModel(_ id: String) -> ChatViewModel {
        ChatViewModel(engineClient: engineClient, sessionId: id, eventStoreManager: nil)
    }

    // MARK: - Per-session recreation

    private func sampleSkill(_ name: String) -> Skill {
        Skill(
            name: name,
            displayName: name,
            description: "",
            source: .global,
            tags: nil
        )
    }

    func testTwoViewModelsForDifferentSessionsHaveIndependentState() {
        let a = makeViewModel("sess-a-\(UUID().uuidString)")
        let b = makeViewModel("sess-b-\(UUID().uuidString)")

        // Seed A with some composition state.
        a.inputBarState.text = "draft for A"
        a.inputBarState.selectedSkills = [sampleSkill("planner")]

        // B is fresh — nothing bled through.
        XCTAssertEqual(b.inputBarState.text, "",
                       "different sessionId must yield a fresh inputBarState")
        XCTAssertTrue(b.inputBarState.selectedSkills.isEmpty,
                      "selected skills must not bleed across ChatViewModel instances")
    }

    func testViewModelStartsInCleanState() {
        let vm = makeViewModel("sess-clean-\(UUID().uuidString)")
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertTrue(vm.inputBarState.text.isEmpty)
        XCTAssertTrue(vm.inputBarState.selectedSkills.isEmpty)
        XCTAssertFalse(vm.isCompacting)
        XCTAssertFalse(vm.isRetaining)
        XCTAssertEqual(vm.agentPhase, .idle)
        XCTAssertEqual(vm.sequenceHighWaterMark, -1)
        XCTAssertEqual(vm.eventBufferCount, 0)
    }

    // MARK: - cleanUpStreamingState scope

    /// Composition state is USER work; a transient reconnect that
    /// triggers cleanUpStreamingState must NOT discard it.
    func testCleanUpStreamingStatePreservesInputComposition() {
        let vm = makeViewModel("sess-preserve-\(UUID().uuidString)")

        vm.inputBarState.text = "typed but not sent"
        vm.inputBarState.selectedSkills = [sampleSkill("reviewer")]

        vm.cleanUpStreamingState()

        XCTAssertEqual(vm.inputBarState.text, "typed but not sent",
                       "user's in-flight composition must survive reconnect")
        XCTAssertEqual(vm.inputBarState.selectedSkills.count, 1,
                       "selected skills must survive reconnect")
    }

    /// In-flight turn state IS cleared — that's the whole purpose of
    /// the method: let reconstruction rebuild it from the log.
    func testCleanUpStreamingStateClearsTurnTracking() {
        let vm = makeViewModel("sess-clear-\(UUID().uuidString)")
        vm.thinkingMessageId = UUID()
        let toolId = UUID()
        vm.currentToolMessages[toolId] = ChatMessage(
            id: toolId,
            role: .assistant,
            content: .text("")
        )
        vm.currentTurnCapabilityInvocations.append(
            CapabilityInvocationRecord(
                invocationId: "t",
                modelToolName: "Bash",
                arguments: ""
            )
        )

        vm.cleanUpStreamingState()

        XCTAssertNil(vm.thinkingMessageId)
        XCTAssertTrue(vm.currentToolMessages.isEmpty)
        XCTAssertTrue(vm.currentTurnCapabilityInvocations.isEmpty)
    }

    /// A completed `session::reconstruct` response is server-authoritative.
    /// It must clear any local live-turn indicators that were left behind by a
    /// dropped socket, a stale post-processing timeout, or an old stream frame.
    func testCompletedReconstructionReconcilesTransientLiveState() {
        let vm = makeViewModel("sess-reconcile-\(UUID().uuidString)")
        vm.agentPhase = .postProcessing
        vm.runningToolCount = 2
        vm.pullUpPanelState.awaitingSuggestions = true
        vm.postProcessingTimeoutTask = Task { try? await Task.sleep(for: .seconds(30)) }
        let thinking = ChatMessage.thinking("still thinking", isStreaming: true)
        vm.appendToMessages(thinking)
        vm.thinkingMessageId = thinking.id
        let toolId = UUID()
        vm.currentToolMessages[toolId] = ChatMessage(id: toolId, role: .assistant, content: .text(""))
        vm.currentTurnCapabilityInvocations.append(CapabilityInvocationRecord(invocationId: "t", modelToolName: "Bash", arguments: "{}"))

        vm.reconcileCompletedReconstructionState()

        XCTAssertEqual(vm.agentPhase, .idle)
        XCTAssertEqual(vm.runningToolCount, 0)
        XCTAssertFalse(vm.pullUpPanelState.awaitingSuggestions)
        XCTAssertNil(vm.postProcessingTimeoutTask)
        XCTAssertTrue(vm.currentToolMessages.isEmpty)
        XCTAssertTrue(vm.currentTurnCapabilityInvocations.isEmpty)
        guard case .thinking(_, _, let isStreaming) = vm.messages[0].content else {
            return XCTFail("expected thinking message")
        }
        XCTAssertFalse(isStreaming)
    }
}
