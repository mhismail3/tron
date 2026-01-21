import XCTest
@testable import TronMobile

@MainActor
final class ContextStateTests: XCTestCase {

    func testInitialState() {
        let state = ContextTrackingState()
        XCTAssertNil(state.totalTokenUsage)
        XCTAssertEqual(state.currentContextWindow, 200_000)
        XCTAssertEqual(state.accumulatedInputTokens, 0)
        XCTAssertEqual(state.accumulatedOutputTokens, 0)
        XCTAssertEqual(state.accumulatedCacheReadTokens, 0)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 0)
        XCTAssertEqual(state.accumulatedCost, 0)
        XCTAssertEqual(state.lastTurnInputTokens, 0)
        XCTAssertEqual(state.previousTurnFinalInputTokens, 0)
    }

    func testContextPercentage() {
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000
        state.lastTurnInputTokens = 100_000

        XCTAssertEqual(state.contextPercentage, 50)
    }

    func testContextPercentageZeroWindow() {
        let state = ContextTrackingState()
        state.currentContextWindow = 0
        state.lastTurnInputTokens = 100_000

        XCTAssertEqual(state.contextPercentage, 0)
    }

    func testContextPercentageZeroTokens() {
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000
        state.lastTurnInputTokens = 0

        XCTAssertEqual(state.contextPercentage, 0)
    }

    func testContextPercentageCapped() {
        let state = ContextTrackingState()
        state.currentContextWindow = 100_000
        state.lastTurnInputTokens = 150_000

        XCTAssertEqual(state.contextPercentage, 100)
    }

    func testAccumulateTokens() {
        let state = ContextTrackingState()

        state.accumulate(
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 200,
            cacheCreationTokens: 100,
            cost: 0.05
        )

        XCTAssertEqual(state.accumulatedInputTokens, 1000)
        XCTAssertEqual(state.accumulatedOutputTokens, 500)
        XCTAssertEqual(state.accumulatedCacheReadTokens, 200)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 100)
        XCTAssertEqual(state.accumulatedCost, 0.05, accuracy: 0.0001)

        // Accumulate more
        state.accumulate(
            inputTokens: 500,
            outputTokens: 250,
            cacheReadTokens: 100,
            cacheCreationTokens: 50,
            cost: 0.025
        )

        XCTAssertEqual(state.accumulatedInputTokens, 1500)
        XCTAssertEqual(state.accumulatedOutputTokens, 750)
        XCTAssertEqual(state.accumulatedCacheReadTokens, 300)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 150)
        XCTAssertEqual(state.accumulatedCost, 0.075, accuracy: 0.0001)
    }

    func testRecordTurnEnd() {
        let state = ContextTrackingState()
        state.lastTurnInputTokens = 5000

        state.recordTurnEnd()

        XCTAssertEqual(state.previousTurnFinalInputTokens, 5000)
    }

    func testTokenDelta() {
        let state = ContextTrackingState()
        state.previousTurnFinalInputTokens = 3000
        state.lastTurnInputTokens = 5000

        XCTAssertEqual(state.tokenDelta, 2000)
    }

    func testTokenDeltaWhenNoPreviousTurn() {
        let state = ContextTrackingState()
        state.previousTurnFinalInputTokens = 0
        state.lastTurnInputTokens = 5000

        XCTAssertEqual(state.tokenDelta, 5000)
    }

    func testReset() {
        let state = ContextTrackingState()
        state.accumulatedInputTokens = 1000
        state.accumulatedOutputTokens = 500
        state.accumulatedCacheReadTokens = 200
        state.accumulatedCacheCreationTokens = 100
        state.accumulatedCost = 0.05
        state.lastTurnInputTokens = 5000
        state.previousTurnFinalInputTokens = 3000

        state.reset()

        XCTAssertEqual(state.accumulatedInputTokens, 0)
        XCTAssertEqual(state.accumulatedOutputTokens, 0)
        XCTAssertEqual(state.accumulatedCacheReadTokens, 0)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 0)
        XCTAssertEqual(state.accumulatedCost, 0)
        XCTAssertEqual(state.lastTurnInputTokens, 0)
        XCTAssertEqual(state.previousTurnFinalInputTokens, 0)
    }

    func testUpdateFromModels() {
        let state = ContextTrackingState()
        let models = [
            createTestModelInfo(id: "claude-opus-4-5-20251101", name: "Opus 4.5", contextWindow: 200_000),
            createTestModelInfo(id: "claude-sonnet-4-20250514", name: "Sonnet 4", contextWindow: 180_000)
        ]

        state.updateContextWindow(from: models, currentModel: "claude-sonnet-4-20250514")

        XCTAssertEqual(state.currentContextWindow, 180_000)
    }

    func testUpdateFromModelsModelNotFound() {
        let state = ContextTrackingState()
        let initialWindow = state.currentContextWindow
        let models = [
            createTestModelInfo(id: "claude-opus-4-5-20251101", name: "Opus 4.5", contextWindow: 200_000)
        ]

        state.updateContextWindow(from: models, currentModel: "unknown-model")

        XCTAssertEqual(state.currentContextWindow, initialWindow)
    }

    // MARK: - Helper Methods

    private func createTestModelInfo(id: String, name: String, contextWindow: Int) -> ModelInfo {
        return ModelInfo(
            id: id,
            name: name,
            provider: "anthropic",
            contextWindow: contextWindow,
            maxOutputTokens: nil,
            supportsThinking: nil,
            supportsImages: nil,
            tier: nil,
            isLegacy: nil,
            supportsReasoning: nil,
            reasoningLevels: nil,
            defaultReasoningLevel: nil,
            thinkingLevel: nil,
            supportedThinkingLevels: nil
        )
    }
}
