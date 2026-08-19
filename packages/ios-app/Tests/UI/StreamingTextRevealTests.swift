import Testing
@testable import TronMobile

@Suite("Streaming text reveal")
struct StreamingTextRevealTests {
    @Test("reveal opacity is monotonic and bounded")
    func opacityIsBounded() {
        #expect(ChatStreamingTextRevealPolicy.opacity(elapsedMilliseconds: 0) == 0)
        #expect(ChatStreamingTextRevealPolicy.opacity(elapsedMilliseconds: 110) == 0.5)
        #expect(ChatStreamingTextRevealPolicy.opacity(elapsedMilliseconds: 10_000) == 1)
        #expect(ChatStreamingTextRevealPolicy.opacity(elapsedMilliseconds: -1) == 0)
    }

    @Test("large initial and live backlogs catch up instead of lagging authoritative text")
    func backlogCatchesUp() {
        #expect(!ChatStreamingTextRevealPolicy.shouldCatchUp(pendingTokenCount: 1, initialTokenCount: 3))
        #expect(ChatStreamingTextRevealPolicy.shouldCatchUp(pendingTokenCount: 1, initialTokenCount: 13))
        #expect(!ChatStreamingTextRevealPolicy.shouldCatchUp(pendingTokenCount: 18))
        #expect(ChatStreamingTextRevealPolicy.shouldCatchUp(pendingTokenCount: 19))
    }
}
