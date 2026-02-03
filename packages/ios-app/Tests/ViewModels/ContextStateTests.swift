import XCTest
@testable import TronMobile

@MainActor
final class ContextStateTests: XCTestCase {

    func testInitialState() {
        let state = ContextTrackingState()
        XCTAssertNil(state.totalTokenUsage)
        XCTAssertEqual(state.currentContextWindow, 200_000)
        XCTAssertEqual(state.newInputTokens, 0)
        XCTAssertEqual(state.contextWindowTokens, 0)
        XCTAssertEqual(state.outputTokens, 0)
        XCTAssertEqual(state.accumulatedInputTokens, 0)
        XCTAssertEqual(state.accumulatedOutputTokens, 0)
        XCTAssertEqual(state.accumulatedCacheReadTokens, 0)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 0)
        XCTAssertEqual(state.accumulatedCost, 0)
    }

    // MARK: - Context Percentage Tests (using server values)

    func testContextPercentage() {
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000
        state.contextWindowTokens = 100_000

        XCTAssertEqual(state.contextPercentage, 50)
    }

    func testContextPercentageZeroWindow() {
        let state = ContextTrackingState()
        state.currentContextWindow = 0
        state.contextWindowTokens = 100_000

        XCTAssertEqual(state.contextPercentage, 0)
    }

    func testContextPercentageZeroTokens() {
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000
        state.contextWindowTokens = 0

        XCTAssertEqual(state.contextPercentage, 0)
    }

    func testContextPercentageCapped() {
        let state = ContextTrackingState()
        state.currentContextWindow = 100_000
        state.contextWindowTokens = 150_000

        XCTAssertEqual(state.contextPercentage, 100)
    }

    func testContextPercentageAt95Percent() {
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000
        state.contextWindowTokens = 190_000

        XCTAssertEqual(state.contextPercentage, 95)
    }

    // MARK: - Tokens Remaining Tests

    func testTokensRemaining() {
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000
        state.contextWindowTokens = 150_000

        XCTAssertEqual(state.tokensRemaining, 50_000)
    }

    func testTokensRemainingNeverNegative() {
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000
        state.contextWindowTokens = 250_000  // Over limit

        XCTAssertEqual(state.tokensRemaining, 0)  // Should be 0, not negative
    }

    // MARK: - updateFromTokenRecord Tests

    func testUpdateFromTokenRecord() {
        let state = ContextTrackingState()

        let record = makeTokenRecord(
            rawInputTokens: 500,
            rawOutputTokens: 100,
            contextWindowTokens: 8500,
            newInputTokens: 500
        )

        state.updateFromTokenRecord(record)

        XCTAssertEqual(state.newInputTokens, 500)
        XCTAssertEqual(state.contextWindowTokens, 8500)
        XCTAssertEqual(state.outputTokens, 100)
    }

    func testUpdateFromTokenRecordUpdatesLastTurnInputTokens() {
        let state = ContextTrackingState()

        let record = makeTokenRecord(
            rawInputTokens: 500,
            rawOutputTokens: 100,
            contextWindowTokens: 8500,
            newInputTokens: 500
        )

        state.updateFromTokenRecord(record)

        // lastTurnInputTokens is now a proxy to contextWindowTokens
        XCTAssertEqual(state.lastTurnInputTokens, 8500)
    }

    // MARK: - Helper Methods

    private func makeTokenRecord(
        rawInputTokens: Int,
        rawOutputTokens: Int,
        contextWindowTokens: Int,
        newInputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) -> TokenRecord {
        TokenRecord(
            source: TokenSource(
                provider: "anthropic",
                timestamp: ISO8601DateFormatter().string(from: Date()),
                rawInputTokens: rawInputTokens,
                rawOutputTokens: rawOutputTokens,
                rawCacheReadTokens: cacheReadTokens,
                rawCacheCreationTokens: cacheCreationTokens
            ),
            computed: ComputedTokens(
                contextWindowTokens: contextWindowTokens,
                newInputTokens: newInputTokens,
                previousContextBaseline: 0,
                calculationMethod: "anthropic_cache_aware"
            ),
            meta: TokenMeta(
                turn: 1,
                sessionId: "test-session",
                extractedAt: ISO8601DateFormatter().string(from: Date()),
                normalizedAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    // MARK: - Accumulation Tests (still needed for billing)

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

    // MARK: - Reset Tests

    func testReset() {
        let state = ContextTrackingState()
        state.newInputTokens = 500
        state.contextWindowTokens = 8500
        state.outputTokens = 100
        state.accumulatedInputTokens = 1000
        state.accumulatedOutputTokens = 500
        state.accumulatedCacheReadTokens = 200
        state.accumulatedCacheCreationTokens = 100
        state.accumulatedCost = 0.05

        state.reset()

        XCTAssertEqual(state.newInputTokens, 0)
        XCTAssertEqual(state.contextWindowTokens, 0)
        XCTAssertEqual(state.outputTokens, 0)
        XCTAssertEqual(state.accumulatedInputTokens, 0)
        XCTAssertEqual(state.accumulatedOutputTokens, 0)
        XCTAssertEqual(state.accumulatedCacheReadTokens, 0)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 0)
        XCTAssertEqual(state.accumulatedCost, 0)
    }

    // MARK: - Model Context Window Update Tests

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

    // MARK: - Integration Test: Model Switch Scenario

    func testModelSwitchResetsCorrectly() {
        let state = ContextTrackingState()

        // First turn with Anthropic
        let record1 = makeTokenRecord(
            rawInputTokens: 500,
            rawOutputTokens: 100,
            contextWindowTokens: 8500,
            newInputTokens: 500,
            cacheReadTokens: 8000
        )
        state.updateFromTokenRecord(record1)

        XCTAssertEqual(state.contextWindowTokens, 8500)
        XCTAssertEqual(state.newInputTokens, 500)

        // Model switch to Codex - server sends full context as newInputTokens
        let record2 = makeTokenRecord(
            rawInputTokens: 11000,
            rawOutputTokens: 50,
            contextWindowTokens: 11000,
            newInputTokens: 11000
        )
        state.updateFromTokenRecord(record2)

        // Verify: iOS just displays what server sends, no local calculation
        XCTAssertEqual(state.newInputTokens, 11000)
        XCTAssertEqual(state.contextWindowTokens, 11000)
    }

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
