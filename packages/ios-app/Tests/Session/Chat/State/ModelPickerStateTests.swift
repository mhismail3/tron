import Testing
import Foundation
import Observation
import SwiftUI
@testable import TronMobile

/// Tests for ModelPickerState
/// Verifies model prefetch, switch, and display name behavior
@MainActor
@Suite("ModelPickerState Tests")
struct ModelPickerStateTests {

    // MARK: - Test Helpers

    /// Repository double whose snapshot can be seeded without production test hooks.
    @Observable
    final class MockModelRepository: ModelRepository {
        var cachedModels: [ModelInfo] = []
        var listCallCount = 0
        var listResult: [ModelInfo] = []
        var listShouldThrow = false

        var switchCallCount = 0
        var switchSessionId: String?
        var switchModelId: String?
        var switchResult: ModelSwitchResult?
        var switchShouldThrow = false
        var reasoningLevelResult: ReasoningLevelResult?
        var onSwitch: (() -> Void)?

        func list(forceRefresh: Bool) async throws -> [ModelInfo] {
            listCallCount += 1
            if listShouldThrow {
                throw TestError.mockError
            }
            cachedModels = listResult
            return listResult
        }

        func switchModel(
            sessionId: String,
            to modelId: String,
            idempotencyKey: EngineIdempotencyKey
        ) async throws -> ModelSwitchResult {
            switchCallCount += 1
            switchSessionId = sessionId
            switchModelId = modelId
            onSwitch?()
            if switchShouldThrow {
                throw TestError.mockError
            }
            return switchResult ?? ModelSwitchResult(previousModel: "", newModel: modelId)
        }

        func setReasoningLevel(
            sessionId: String,
            level: String,
            idempotencyKey: EngineIdempotencyKey
        ) async throws -> ReasoningLevelResult {
            reasoningLevelResult ?? ReasoningLevelResult(
                previousLevel: nil,
                newLevel: level,
                changed: true
            )
        }

        func invalidateCache() {
            cachedModels = []
        }

        enum TestError: Error {
            case mockError
        }
    }

    // MARK: - Presentation Policy Tests

    @Test("Model picker chrome uses the emerald product accent")
    func modelPickerChromeUsesEmeraldAccent() {
        #expect(ModelPickerPresentation.primaryAccent == Color.tronEmerald)
    }

    @Test("OpenAI uses a readable neutral accent only in dark mode")
    func openAIUsesReadableNeutralAccentOnlyInDarkMode() {
        #expect(ModelPickerPresentation.usesHighContrastNeutral(
            providerId: "openai-codex",
            isDark: true
        ))
        #expect(!ModelPickerPresentation.usesHighContrastNeutral(
            providerId: "openai-codex",
            isDark: false
        ))
        #expect(!ModelPickerPresentation.usesHighContrastNeutral(
            providerId: "anthropic",
            isDark: true
        ))
    }

    /// Create test model info
    static func makeModelInfo(
        id: String,
        name: String = "",
        contextWindow: Int = 200_000,
        isRetiredGeneration: Bool = false,
        sortOrder: Int? = nil
    ) -> ModelInfo {
        // I8: the five required fields (supportsThinking/Images/Documents,
        // tier, isRetiredGeneration) have no defaults — callers pass them explicitly.
        ModelInfo(
            id: id,
            name: name.isEmpty ? id : name,
            provider: "anthropic",
            contextWindow: contextWindow,
            supportsThinking: true,
            supportsImages: true,
            supportsDocuments: false,
            tier: "sonnet",
            isRetiredGeneration: isRetiredGeneration,
            maxOutputTokens: 8192,
            sortOrder: sortOrder
        )
    }

    // MARK: - Initial State Tests

    @Test("Initial state has no optimistic model")
    func testInitialState_hasNoOptimisticModel() {
        let repository = MockModelRepository()
        let state = ModelPickerState(modelRepository: repository)

        #expect(state.optimisticModelName == nil)
    }

    // MARK: - Display Name Tests

    @Test("Display name returns current when no optimistic")
    func testDisplayModelName_returnsCurrentWhenNoOptimistic() {
        let repository = MockModelRepository()
        let state = ModelPickerState(modelRepository: repository)

        let result = state.displayModelName(current: "claude-opus-4-20250514")

        #expect(result == "claude-opus-4-20250514")
    }

    // MARK: - Current Model Info Tests

    @Test("Current model info finds matching model")
    func testCurrentModelInfo_findsMatchingModel() {
        let repository = MockModelRepository()
        let state = ModelPickerState(modelRepository: repository)
        let targetModel = Self.makeModelInfo(id: "claude-opus-4-20250514", name: "Claude Opus 4")
        let otherModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4")
        repository.cachedModels = [otherModel, targetModel]

        let result = state.currentModelInfo(current: "claude-opus-4-20250514")

        #expect(result?.id == "claude-opus-4-20250514")
    }

    @Test("Current model info returns nil when not found")
    func testCurrentModelInfo_returnsNilWhenNotFound() {
        let repository = MockModelRepository()
        let state = ModelPickerState(modelRepository: repository)
        let model = Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        repository.cachedModels = [model]

        let result = state.currentModelInfo(current: "claude-opus-4-20250514")

        #expect(result == nil)
    }

    @Test("Current model info resolves a provider-local restored identifier")
    func testCurrentModelInfo_resolvesProviderLocalIdentifier() {
        let repository = MockModelRepository()
        let state = ModelPickerState(modelRepository: repository)
        repository.cachedModels = [
            Self.makeModelInfo(id: "openai/gpt-5.6-sol", name: "GPT-5.6 Sol")
        ]

        let result = state.currentModelInfo(current: "gpt-5.6-sol")

        #expect(result?.contextWindow == 200_000)
    }

    @Test("Repository catalog observation flows through picker metadata lookup")
    func testRepositoryCatalogObservationFlowsThroughPicker() {
        let repository = MockModelRepository()
        let state = ModelPickerState(modelRepository: repository)
        let changed = DispatchSemaphore(value: 0)

        withObservationTracking {
            _ = state.currentModelInfo(current: "claude-opus-4-20250514")
        } onChange: {
            changed.signal()
        }
        repository.cachedModels = [Self.makeModelInfo(id: "claude-opus-4-20250514")]

        #expect(changed.wait(timeout: .now() + 1) == .success)
    }

    @Test("Display helpers use the optimistic model during a switch")
    func testDisplayHelpers_useOptimisticModelDuringSwitch() async {
        let repository = MockModelRepository()
        let state = ModelPickerState(modelRepository: repository)
        let opusModel = Self.makeModelInfo(id: "claude-opus-4-20250514")
        let sonnetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        repository.cachedModels = [opusModel, sonnetModel]
        var displayedName: String?
        var displayedModelId: String?
        repository.onSwitch = {
            displayedName = state.displayModelName(current: opusModel.id)
            displayedModelId = state.currentModelInfo(current: opusModel.id)?.id
        }

        await state.switchModel(
            to: sonnetModel,
            sessionId: "test-session",
            currentModel: opusModel.id,
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in }
        )

        #expect(displayedName == sonnetModel.id)
        #expect(displayedModelId == sonnetModel.id)
    }

    // MARK: - Prefetch Models Tests

    @Test("Prefetch delegates catalog ownership to the repository")
    func testPrefetchModels_delegatesCatalogOwnership() async {
        let repository = MockModelRepository()
        let models = [
            Self.makeModelInfo(id: "claude-opus-4-20250514"),
            Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        ]
        repository.listResult = models
        let state = ModelPickerState(modelRepository: repository)

        await state.prefetchModels(onContextUpdate: { _ in })

        #expect(repository.listCallCount == 1)
        #expect(repository.cachedModels.map(\.id) == models.map(\.id))
        #expect(state.currentModelInfo(current: models[0].id)?.id == models[0].id)
    }

    @Test("Prefetch models calls onContextUpdate")
    func testPrefetchModels_callsOnContextUpdate() async {
        let repository = MockModelRepository()
        let models = [Self.makeModelInfo(id: "claude-opus-4-20250514")]
        repository.listResult = models
        let state = ModelPickerState(modelRepository: repository)
        var receivedModels: [ModelInfo]?

        await state.prefetchModels(onContextUpdate: { models in
            receivedModels = models
        })

        #expect(receivedModels?.count == 1)
        #expect(receivedModels?.first?.id == "claude-opus-4-20250514")
    }

    @Test("Prefetch models handles error gracefully")
    func testPrefetchModels_handlesError_keepsEmptyList() async {
        let repository = MockModelRepository()
        repository.listShouldThrow = true
        let state = ModelPickerState(modelRepository: repository)
        var contextUpdateCalled = false

        await state.prefetchModels(onContextUpdate: { _ in contextUpdateCalled = true })

        #expect(repository.cachedModels.isEmpty)
        #expect(!contextUpdateCalled)
    }

    // MARK: - Switch Model Tests

    @Test("Switch model sets optimistic name")
    func testSwitchModel_setsOptimisticName() async {
        let repository = MockModelRepository()
        repository.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelRepository: repository)
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
            onError: { _, _ in }
        )

        #expect(optimisticDuringSwitch == "claude-sonnet-4-20250514")
    }

    @Test("Switch model calls engine protocol with correct params")
    func testSwitchModel_callsEngineProtocolWithCorrectParams() async {
        let repository = MockModelRepository()
        repository.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelRepository: repository)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session-123",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in }
        )

        #expect(repository.switchCallCount == 1)
        #expect(repository.switchSessionId == "test-session-123")
        #expect(repository.switchModelId == "claude-sonnet-4-20250514")
    }

    @Test("Switch model clears optimistic on success")
    func testSwitchModel_clearsOptimisticOnSuccess() async {
        let repository = MockModelRepository()
        repository.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelRepository: repository)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in }
        )

        #expect(state.optimisticModelName == nil)
    }

    @Test("Switch model calls onSuccess with correct models")
    func testSwitchModel_callsOnSuccessCallback() async {
        let repository = MockModelRepository()
        repository.switchResult = ModelSwitchResult(
            previousModel: "claude-opus-4-20250514",
            newModel: "claude-sonnet-4-20250514"
        )
        let state = ModelPickerState(modelRepository: repository)
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
            onError: { _, _ in }
        )

        #expect(receivedPrevious == "claude-opus-4-20250514")
        #expect(receivedNew == "claude-sonnet-4-20250514")
    }

    @Test("Switch model clears optimistic on failure")
    func testSwitchModel_clearsOptimisticOnFailure() async {
        let repository = MockModelRepository()
        repository.switchShouldThrow = true
        let state = ModelPickerState(modelRepository: repository)
        let targetModel = Self.makeModelInfo(id: "claude-sonnet-4-20250514")

        await state.switchModel(
            to: targetModel,
            sessionId: "test-session",
            currentModel: "claude-opus-4-20250514",
            onOptimisticSet: { _ in },
            onSuccess: { _, _ in },
            onError: { _, _ in }
        )

        #expect(state.optimisticModelName == nil)
    }

    // MARK: - isLatestGeneration Tests (isRetiredGeneration-driven)

    @Test("isRetiredGeneration: false → isLatestGeneration: true")
    func testIsLatestGeneration_notRetired() {
        let model = Self.makeModelInfo(id: "claude-opus-4-6", isRetiredGeneration: false)
        #expect(model.isLatestGeneration == true)
    }

    @Test("isRetiredGeneration: true → isLatestGeneration: false")
    func testIsLatestGeneration_retired() {
        let model = Self.makeModelInfo(id: "claude-opus-4-5-20251101", isRetiredGeneration: true)
        #expect(model.isLatestGeneration == false)
    }

    @Test("Opus 4.6 supports reasoning")
    func testOpus46SupportsReasoning() {
        // I8: the five required fields precede the optional metadata.
        let model = ModelInfo(
            id: "claude-opus-4-6",
            name: "Opus 4.6",
            provider: "anthropic",
            contextWindow: 200_000,
            supportsThinking: true,
            supportsImages: true,
            supportsDocuments: true,
            tier: "opus",
            isRetiredGeneration: false,
            maxOutputTokens: 128_000,
            supportsReasoning: true,
            reasoningLevels: ["low", "medium", "high", "max"],
            defaultReasoningLevel: "high"
        )
        #expect(model.supportsReasoning == true)
        #expect(model.reasoningLevels?.count == 4)
        #expect(model.defaultReasoningLevel == "high")
    }

    @Test("reasoning control is hidden when picker has no bound reasoning state")
    func testReasoningControlHiddenWithoutBoundReasoningState() {
        let model = ModelInfo(
            id: "claude-opus-4-6",
            name: "Opus 4.6",
            provider: "anthropic",
            contextWindow: 200_000,
            supportsThinking: true,
            supportsImages: true,
            supportsDocuments: true,
            tier: "opus",
            isRetiredGeneration: false,
            supportsReasoning: true,
            reasoningLevels: ["low", "medium", "high", "max"]
        )

        #expect(ModelPickerReasoningVisibility.showsReasoningControl(
            selectedModel: model,
            reasoningLevel: nil
        ) == false)
    }

    @Test("reasoning control is visible when model and caller both support reasoning")
    func testReasoningControlVisibleWithBoundReasoningState() {
        let model = ModelInfo(
            id: "claude-opus-4-6",
            name: "Opus 4.6",
            provider: "anthropic",
            contextWindow: 200_000,
            supportsThinking: true,
            supportsImages: true,
            supportsDocuments: true,
            tier: "opus",
            isRetiredGeneration: false,
            supportsReasoning: true,
            reasoningLevels: ["low", "medium", "high", "max"]
        )

        #expect(ModelPickerReasoningVisibility.showsReasoningControl(
            selectedModel: model,
            reasoningLevel: "medium"
        ))
    }

    @Test("Switch model calls onError callback with error message")
    func testSwitchModel_callsOnErrorCallback() async {
        let repository = MockModelRepository()
        repository.switchShouldThrow = true
        let state = ModelPickerState(modelRepository: repository)
        repository.cachedModels = [
            Self.makeModelInfo(id: "claude-opus-4-20250514"),
            Self.makeModelInfo(id: "claude-sonnet-4-20250514")
        ]
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
            }
        )

        #expect(receivedError != nil)
        #expect(receivedRevertModel?.id == "claude-opus-4-20250514")
    }
}
