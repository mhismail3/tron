import Testing
@testable import TronMobile

@Suite("Provider display formatting")
struct ProviderDisplayFormattingTests {
    @Test("formats Anthropic model identifiers without losing decimal versions")
    func anthropicModelVersions() {
        #expect(ModelDisplayFormatting.model("claude-opus-5-5") == "Claude Opus 5.5")
        #expect(ModelDisplayFormatting.model("claude-opus-5-5") == ModelDisplayFormatting.model("Claude Opus 5.5"))
        #expect(ModelDisplayFormatting.model("claude-fable-5-1") == "Claude Fable 5.1")
        #expect(ModelDisplayFormatting.model("claude-mythos-5-1") == "Claude Mythos 5.1")
        #expect(ModelDisplayFormatting.model("claude-opus-4-8") == "Claude Opus 4.8")
        #expect(ModelDisplayFormatting.model("claude-opus-4-5") == "Claude Opus 4.5")
        #expect(ModelDisplayFormatting.model("claude-sonnet-4-5") == "Claude Sonnet 4.5")
    }

    @Test("preserves CortexKit branding in provider names")
    func cortexKitBranding() {
        #expect(ModelDisplayFormatting.provider("Anthropic (CortexKit)") == "Anthropic (CortexKit)")
    }
}
