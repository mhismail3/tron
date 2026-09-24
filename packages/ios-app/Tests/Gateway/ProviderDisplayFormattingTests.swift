import Testing
@testable import TronMobile

@Suite("Provider display formatting")
struct ProviderDisplayFormattingTests {
    @Test("preserves CortexKit branding in provider names")
    func cortexKitBranding() {
        #expect(ModelDisplayFormatting.provider("Anthropic (CortexKit)") == "Anthropic (CortexKit)")
    }
}
