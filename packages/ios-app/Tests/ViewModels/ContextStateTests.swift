import XCTest
@testable import TronMobile

@MainActor
final class ContextStateTests: XCTestCase {

    func testInitialState() {
        let state = ContextTrackingState()
        XCTAssertNil(state.totalTokenUsage)
        XCTAssertEqual(state.currentContextWindow, 0)
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

    // MARK: - setAccumulatedTokens Tests

    func testSetAccumulatedTokens() {
        let state = ContextTrackingState()
        state.accumulatedInputTokens = 999
        state.accumulatedOutputTokens = 999

        let usage = TokenUsage(inputTokens: 5000, outputTokens: 2000, cacheReadTokens: 1500, cacheCreationTokens: 300)
        state.setAccumulatedTokens(from: usage)

        XCTAssertEqual(state.accumulatedInputTokens, 5000)
        XCTAssertEqual(state.accumulatedOutputTokens, 2000)
        XCTAssertEqual(state.accumulatedCacheReadTokens, 1500)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 300)
    }

    func testSetAccumulatedTokensWithNilCacheValues() {
        let state = ContextTrackingState()
        let usage = TokenUsage(inputTokens: 5000, outputTokens: 2000, cacheReadTokens: nil, cacheCreationTokens: nil)
        state.setAccumulatedTokens(from: usage)

        XCTAssertEqual(state.accumulatedCacheReadTokens, 0)
        XCTAssertEqual(state.accumulatedCacheCreationTokens, 0)
    }

    // MARK: - setTotalTokenUsage Tests

    func testSetTotalTokenUsage() {
        let state = ContextTrackingState()
        let usage = TokenUsage(inputTokens: 5000, outputTokens: 2000, cacheReadTokens: 1500, cacheCreationTokens: 300)
        state.setTotalTokenUsage(contextWindowSize: 85000, from: usage)

        XCTAssertNotNil(state.totalTokenUsage)
        XCTAssertEqual(state.totalTokenUsage?.inputTokens, 85000)
        XCTAssertEqual(state.totalTokenUsage?.outputTokens, 2000)
        XCTAssertEqual(state.totalTokenUsage?.cacheReadTokens, 1500)
        XCTAssertEqual(state.totalTokenUsage?.cacheCreationTokens, 300)
    }

    // MARK: - lastTurnInputTokens Alias Tests

    func testLastTurnInputTokensAliasesContextWindowTokens() {
        let state = ContextTrackingState()
        state.lastTurnInputTokens = 42000
        XCTAssertEqual(state.contextWindowTokens, 42000)
        XCTAssertEqual(state.lastTurnInputTokens, 42000)

        state.contextWindowTokens = 99000
        XCTAssertEqual(state.lastTurnInputTokens, 99000)
    }

    // MARK: - Reconstruction Restoration Integration Tests

    func testReconstructionRestorationFlow() {
        // Simulates the exact flow that processReconstructionResult should follow
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000  // Set by prefetchModels or refreshContextFromServer

        // Simulate what updateTokenState does with reconstruction data
        let usage = TokenUsage(inputTokens: 15000, outputTokens: 3000, cacheReadTokens: 12000, cacheCreationTokens: 500)
        state.setAccumulatedTokens(from: usage)
        state.lastTurnInputTokens = 85000  // From ReconstructedState.lastTurnInputTokens
        state.setTotalTokenUsage(contextWindowSize: 85000, from: usage)

        // Verify the pill values are correct
        XCTAssertEqual(state.contextWindowTokens, 85000)
        XCTAssertEqual(state.contextPercentage, 43)  // 85000/200000 = 42.5, rounded to 43
        XCTAssertEqual(state.tokensRemaining, 115_000)
    }

    func testReconstructionRestorationWithoutContextWindow() {
        // If currentContextWindow hasn't been set yet (race condition), pill shows 0%
        let state = ContextTrackingState()
        // currentContextWindow defaults to 0

        let usage = TokenUsage(inputTokens: 15000, outputTokens: 3000, cacheReadTokens: nil, cacheCreationTokens: nil)
        state.setAccumulatedTokens(from: usage)
        state.lastTurnInputTokens = 85000

        // contextWindowTokens IS set, but percentage is 0 because denominator is 0
        XCTAssertEqual(state.contextWindowTokens, 85000)
        XCTAssertEqual(state.contextPercentage, 0)

        // Once currentContextWindow is set (by refreshContextFromServer), pill updates
        state.currentContextWindow = 200_000
        XCTAssertEqual(state.contextPercentage, 43)
    }

    func testReconstructionRestorationPostCompaction() {
        // After compaction, lastTurnInputTokens reflects the reduced context size
        let state = ContextTrackingState()
        state.currentContextWindow = 200_000

        let usage = TokenUsage(inputTokens: 180000, outputTokens: 50000, cacheReadTokens: nil, cacheCreationTokens: nil)
        state.setAccumulatedTokens(from: usage)
        state.lastTurnInputTokens = 45000  // Post-compaction: was ~180k, now ~45k
        state.setTotalTokenUsage(contextWindowSize: 45000, from: usage)

        XCTAssertEqual(state.contextWindowTokens, 45000)
        XCTAssertEqual(state.contextPercentage, 23)  // 45000/200000 = 22.5, rounded to 23
        XCTAssertEqual(state.tokensRemaining, 155_000)
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
