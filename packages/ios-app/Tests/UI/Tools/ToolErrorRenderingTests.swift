import Testing
@testable import TronMobile

@Suite("Tool error rendering")
struct ToolErrorRenderingTests {
    @Test("tool error classification is data only")
    func classificationStoresServerMetadata() {
        let classification = ToolErrorClassification(
            code: "DENIED_BY_POLICY",
            category: "policy",
            message: "Tool execution was denied",
            recoverable: true
        )

        #expect(classification.code == "DENIED_BY_POLICY")
        #expect(classification.category == "policy")
        #expect(classification.recoverable == true)
    }
}
