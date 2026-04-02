import Testing
import Foundation
@testable import TronMobile

@Suite("TokenStateManager History Cap")
@MainActor
struct TokenStateManagerHistoryTests {

    private func makeRecord(turn: Int) -> TokenRecord {
        TokenRecord(
            source: TokenSource(
                provider: "test",
                timestamp: "2026-01-01T00:00:00Z",
                rawInputTokens: 100,
                rawOutputTokens: 50,
                rawCacheReadTokens: 0,
                rawCacheCreationTokens: 0
            ),
            computed: ComputedTokens(
                contextWindowTokens: 100,
                newInputTokens: 100,
                previousContextBaseline: 0,
                calculationMethod: "test"
            ),
            meta: TokenMeta(
                turn: turn,
                sessionId: "test-session",
                extractedAt: "2026-01-01T00:00:00Z",
                normalizedAt: "2026-01-01T00:00:00Z"
            )
        )
    }

    @Test("history grows when records are added")
    func historyGrows() {
        let manager = TokenStateManager()
        manager.updateFromTurnEnd(makeRecord(turn: 1))
        manager.updateFromTurnEnd(makeRecord(turn: 2))
        manager.updateFromTurnEnd(makeRecord(turn: 3))
        #expect(manager.history.count == 3)
    }

    @Test("history is capped at 200 entries")
    func historyCapped() {
        let manager = TokenStateManager()
        for turn in 1...250 {
            manager.updateFromTurnEnd(makeRecord(turn: turn))
        }
        #expect(manager.history.count == 200)
    }

    @Test("oldest entries are evicted first")
    func oldestEvicted() {
        let manager = TokenStateManager()
        for turn in 1...210 {
            manager.updateFromTurnEnd(makeRecord(turn: turn))
        }
        #expect(manager.history.count == 200)
        // Oldest should be turn 11 (turns 1-10 evicted)
        #expect(manager.history.first?.meta.turn == 11)
        #expect(manager.history.last?.meta.turn == 210)
    }

    @Test("reset clears history")
    func resetClearsHistory() {
        let manager = TokenStateManager()
        for turn in 1...5 {
            manager.updateFromTurnEnd(makeRecord(turn: turn))
        }
        #expect(manager.history.count == 5)
        manager.reset()
        #expect(manager.history.isEmpty)
    }
}
