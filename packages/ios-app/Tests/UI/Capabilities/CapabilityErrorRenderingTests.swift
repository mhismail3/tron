import Testing
@testable import TronMobile

@Suite("Capability error rendering")
struct CapabilityErrorRenderingTests {
    @Test("capability error classification is data only")
    func classificationStoresServerMetadata() {
        let classification = CapabilityErrorClassification(
            code: "DENIED_BY_POLICY",
            category: "policy",
            message: "Capability execution was denied",
            recoverable: true
        )

        #expect(classification.code == "DENIED_BY_POLICY")
        #expect(classification.category == "policy")
        #expect(classification.recoverable == true)
    }
}
