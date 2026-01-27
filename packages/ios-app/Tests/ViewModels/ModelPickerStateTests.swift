import Testing
import Foundation
@testable import TronMobile

/// Tests for ModelPickerState
/// Verifies model prefetch, switch, and display name behavior
@MainActor
@Suite("ModelPickerState Tests")
struct ModelPickerStateTests {

    // MARK: - Test Helpers

    /// Mock model client for testing
    final class MockModelClient: ModelClientProtocol {
        var listCallCount = 0
        var listResult: [ModelInfo] = []
        var listShouldThrow = false

        var switchCallCount = 0
        var switchSessionId: String?
        var switchModelId: String?
        var switchResult: ModelSwitchResult?
        var switchShouldThrow = false

        func list(forceRefresh: Bool) async throws -> [ModelInfo] {
            listCallCount += 1
            if listShouldThrow {
                throw TestError.mockError
            }
            return listResult
        }

        func switchModel(_ sessionId: String, model: String) async throws -> ModelSwitchResult {
            switchCallCount += 1
            switchSessionId = sessionId
            switchModelId = model
            if switchShouldThrow {
                throw TestError.mockError
            }
            return switchResult ?? ModelSwitchResult(previousModel: "", newModel: model)
        }

        enum TestError: Error {
            case mockError
        }
    }

    /// Create test model info
    static func makeModelInfo(
        id: String,
        name: String = "",
        contextWindow: Int = 200_000
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            name: name.isEmpty ? id : name,
            provider: "anthropic",
            contextWindow: contextWindow,
            maxOutputTokens: 8192,
            supportsThinking: true,
            supportsImages: true,
            tier: nil,
            isLegacy: false,
            supportsReasoning: nil,
            reasoningLevels: nil,
            defaultReasoningLevel: nil,
            thinkingLevel: nil,
            supportedThinkingLevels: nil
        )
    }

    // MARK: - Initial State Tests

    @Test("Initial state has empty cached models")
    func testInitialState_cachedModelsEmpty() {
        let mockClient = MockModelClient()
        let state = ModelPickerState(modelClient: mockClient)

        #expect(state.cachedModels.isEmpty)
        #expect(!state.isLoadingModels)
        #expect(state.optimisticModelName == nil)
    }

    // MARK: - Display Name Tests

    @Test("Display name returns optimistic when set")
    func testDisplayModelName_returnsOptimisticWhenSet() {
        let mockClient = MockModelClient()
        let state = ModelPickerState(modelClient: mockClient)
        state.setOptimisticModelName("claude-sonnet-4-20250514")

        let result = state.displayModelName(current: "claude-opus-4-20250514")

        #expect(result == "claude-sonnet-4-20250514")
    }

    @Test("Display name returns current when no optimistic")
    func testDisplayModelName_returnsCurrentWhenNoOptimistic() {
        let mockClient = MockModelClient()
        let state = ModelPickerState(modelClient: mockClient)

        let result = state.displayModelName(current: "claude-opus-4-20250514")

        #expect(result == "claude-opus-4-20250514")
    }

    // MARK: - Current Model Info Tests

    @Test("Current model info finds matching model")
    func testCurrentModelInfo_findsMatchingModel() {
        let mockClient = MockModelClient()
        let state = ModelPickerState(modelClient: mockClient)
        let targetModel = Self.makeModelInfo(id: "claude-opus-4-20250514", name: "Claude Opus 4")
        let otherModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4")
        state.setCachedModels([otherModel, targetModel])

        let result = state.currentModelInfo(current: "claude-opus-4-20250514")

        #expect(result?.id == "claude-opus-4-20250514")
    }

    @Test("Current model info returns nil when not found")
    func testCurrentModelInfo_returnsNilWhenNotFound() {
        let mockClient = MockModelClient()
        let state = ModelPickerState(modelClient: mockClient)
        let model = Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        state.setCachedModels([model])

        let result = state.currentModelInfo(current: "claude-opus-4-20250514")

        #expect(result == nil)
    }

    @Test("Current model info uses optimistic name when set")
    func testCurrentModelInfo_usesOptimisticWhenSet() {
        let mockClient = MockModelClient()
        let state = ModelPickerState(modelClient: mockClient)
        let opusModel = Self.makeModelInfo(id: "claude-opus-4-20250514")
        let sonnetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        state.setCachedModels([opusModel, sonnetModel])
        state.setOptimisticModelName("claude-sonnet-4-20250514")

        // Current is opus but optimistic is sonnet
        let result = state.currentModelInfo(current: "claude-opus-4-20250514")

        #expect(result?.id == "claude-sonnet-4-20250514")
    }

    // MARK: - Prefetch Models Tests

    @Test("Prefetch models sets loading true then false")
    func testPrefetchModels_setsLoadingTrueThenFalse() async {
        let mockClient = MockModelClient()
        mockClient.listResult = [Self.makeModelInfo(id: "claude-opus-4-20250514")]
        let state = ModelPickerState(modelClient: mockClient)

        await state.prefetchModels(onContextUpdate: { _ in })

        // After completion, loading should be false
        #expect(!state.isLoadingModels)
    }

    @Test("Prefetch models populates cached models")
    func testPrefetchModels_populatesCachedModels() async {
        let mockClient = MockModelClient()
        let models = [
            Self.makeModelInfo(id: "claude-opus-4-20250514"),
            Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        ]
        mockClient.listResult = models
        let state = ModelPickerState(modelClient: mockClient)

        await state.prefetchModels(onContextUpdate: { _ in })

        #expect(state.cachedModels.count == 2)
        #expect(state.cachedModels[0].id == "claude-opus-4-20250514")
    }

    @Test("Prefetch models calls onContextUpdate")
    func testPrefetchModels_callsOnContextUpdate() async {
        let mockClient = MockModelClient()
        let models = [Self.makeModelInfo(id: "claude-opus-4-20250514")]
        mockClient.listResult = models
        let state = ModelPickerState(modelClient: mockClient)
        var receivedModels: [ModelInfo]?

        await state.prefetchModels(onContextUpdate: { models in
            receivedModels = models
        })

        #expect(receivedModels?.count == 1)
        #expect(receivedModels?.first?.id == "claude-opus-4-20250514")
    }

    @Test("Prefetch models handles error gracefully")
    func testPrefetchModels_handlesError_keepsEmptyList() async {
        let mockClient = MockModelClient()
        mockClient.listShouldThrow = true
        let state = ModelPickerState(modelClient: mockClient)

        await state.prefetchModels(onContextUpdate: { _ in })

        #expect(state.cachedModels.isEmpty)
        #expect(!state.isLoadingModels)
    }

    // MARK: - Switch Model Tests

    @Test("Switch model sets optimistic name")
    func testSwitchModel_setsOptimisticName() async {
        let mockClient = MockModelClient()
        mockClient.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelClient: mockClient)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")

        // Use a continuation to capture the optimistic state during switch
        var optimisticDuringSwitch: String?
        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { optimistic in
                optimisticDuringSwitch = optimistic
            },
            onSuccess: { _, _ in },
            onError: { _, _ in },
            onContextRefresh: { }
        )

        #expect(optimisticDuringSwitch == "claude-sonnet-4-20250514")
    }

    @Test("Switch model calls RPC with correct params")
    func testSwitchModel_callsRPCWithCorrectParams() async {
        let mockClient = MockModelClient()
        mockClient.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelClient: mockClient)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session-123",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in },
            onContextRefresh: { }
        )

        #expect(mockClient.switchCallCount == 1)
        #expect(mockClient.switchSessionId == "test-session-123")
        #expect(mockClient.switchModelId == "claude-sonnet-4-20250514")
    }

    @Test("Switch model clears optimistic on success")
    func testSwitchModel_clearsOptimisticOnSuccess() async {
        let mockClient = MockModelClient()
        mockClient.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelClient: mockClient)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in },
            onContextRefresh: { }
        )

        #expect(state.optimisticModelName == nil)
    }

    @Test("Switch model calls onSuccess with correct models")
    func testSwitchModel_callsOnSuccessCallback() async {
        let mockClient = MockModelClient()
        mockClient.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelClient: mockClient)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        var receivedPrevious: String?
        var receivedNew: String?

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { prev, new in
                receivedPrevious = prev
                receivedNew = new
            },
            onError: { _, _ in },
            onContextRefresh: { }
        )

        #expect(receivedPrevious == "claude-opus-4-20250514")
        #expect(receivedNew == "claude-sonnet-4-20250514")
    }

    @Test("Switch model calls onContextRefresh on success")
    func testSwitchModel_callsOnContextRefresh() async {
        let mockClient = MockModelClient()
        mockClient.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelClient: mockClient)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        var refreshCalled = false

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in },
            onContextRefresh: { refreshCalled = true }
        )

        #expect(refreshCalled)
    }

    @Test("Switch model clears optimistic on failure")
    func testSwitchModel_clearsOptimisticOnFailure() async {
        let mockClient = MockModelClient()
        mockClient.switchShouldThrow = true
        let state = ModelPickerState(modelClient: mockClient)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in },
            onContextRefresh: { }
        )

        #expect(state.optimisticModelName == nil)
    }

    @Test("Switch model calls onError callback with error message")
    func testSwitchModel_callsOnErrorCallback() async {
        let mockClient = MockModelClient()
        mockClient.switchShouldThrow = true
        let state = ModelPickerState(modelClient: mockClient)
        state.setCachedModels([
            Self.makeModelInfo(id: "claude-opus-4-20250514"),
            Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        ])
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        var receivedError: String?
        var receivedRevertModel: ModelInfo?

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { error, revert in
                receivedError = error
                receivedRevertModel = revert
            },
            onContextRefresh: { }
        )

        #expect(receivedError != nil)
        #expect(receivedRevertModel?.id == "claude-opus-4-20250514")
    }
}
