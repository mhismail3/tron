import Testing
@testable import TronMobile

@Suite("Privacy-safe performance signposts")
struct PerformanceSignpostsTests {
    @Test("operation vocabulary is closed over the approved Phase 0 boundaries")
    func approvedOperations() {
        #expect(PerformanceOperation.allCases == [
            .gatewayConnect,
            .sessionOpen,
            .sessionSync,
            .sessionResync,
            .receiptResolution,
            .cacheLoad,
            .cacheSave,
            .chatProjection,
            .firstReadyFrame,
            .scrollCommandSettle,
            .prependSettle,
            .terminalAttachReplay,
        ])
    }

    @Test("metadata is numeric and clamps invalid aggregate counts")
    func numericMetadata() {
        #expect(PerformanceMetrics(itemCount: -1, byteCount: -2) == .none)
        #expect(PerformanceMetrics(itemCount: 7, byteCount: 4_096).itemCount == 7)
        #expect(PerformanceMetrics(itemCount: 7, byteCount: 4_096).byteCount == 4_096)
    }
}
