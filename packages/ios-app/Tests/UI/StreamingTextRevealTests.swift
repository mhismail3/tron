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

    @Test("thinking trace height grows naturally and caps at four measured lines")
    func thinkingTraceHeight() {
        #expect(ChatThinkingTraceLayoutPolicy.maximumLines == 4)
        #expect(ChatThinkingTraceLayoutPolicy.initialViewportHeight() == 16)
        #expect(ChatThinkingTraceLayoutPolicy.initialViewportHeight(lineCount: 4) == 64)
        #expect(ChatThinkingTraceLayoutPolicy.viewportHeight(contentHeight: 12, maximumHeight: 64) == 12)
        #expect(ChatThinkingTraceLayoutPolicy.viewportHeight(contentHeight: 96, maximumHeight: 64) == 64)
        #expect(!ChatThinkingTraceLayoutPolicy.isOverflowing(contentHeight: 64, maximumHeight: 64))
        #expect(ChatThinkingTraceLayoutPolicy.isOverflowing(contentHeight: 64.6, maximumHeight: 64))
        #expect(ChatThinkingTraceLayoutPolicy.tailOffset(contentHeight: 96, viewportHeight: 64) == 32)
        #expect(ChatThinkingTraceLayoutPolicy.tailOffset(contentHeight: 48, viewportHeight: 64) == 0)
        #expect(ChatThinkingTraceLayoutPolicy.showsEarlierContent(contentHeight: 96, maximumHeight: 64))
        #expect(!ChatThinkingTraceLayoutPolicy.showsEarlierContent(contentHeight: 48, maximumHeight: 64))
    }
}
