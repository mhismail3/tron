import Testing
@testable import TronMobile

@Suite("Model display formatting")
struct ModelDisplayFormattingTests {
    @Test("provider and model identifiers become readable labels")
    func formatsCanonicalExamples() {
        #expect(ModelDisplayFormatting.provider("openai-codex") == "OpenAI Codex")
        #expect(ModelDisplayFormatting.model("gpt-5.6-luna") == "GPT 5.6 Luna")
        #expect(ModelDisplayFormatting.reference(provider: "openai-codex", model: "gpt-5.6-luna") == "OpenAI Codex / GPT 5.6 Luna")
    }

    @Test("known provider and model vocabulary preserves product casing")
    func preservesProductCasing() {
        #expect(ModelDisplayFormatting.provider("github-copilot") == "GitHub Copilot")
        #expect(ModelDisplayFormatting.provider("azure-openai") == "Azure OpenAI")
        #expect(ModelDisplayFormatting.model("o3-mini") == "O3 Mini")
        #expect(ModelDisplayFormatting.model("claude-3-7-sonnet") == "Claude 3 7 Sonnet")
    }

    @Test("model and provider projections use the centralized labels")
    func projectionsUseLabels() {
        let ref = ModelRef(provider: "openai-codex", id: "gpt-5.6-sol")
        #expect(ref.displayName == "GPT 5.6 Sol")
        #expect(ref.displayDescription == "OpenAI Codex / GPT 5.6 Sol")

        let provider = ProviderSummary(
            id: "openai-codex",
            name: "openai-codex",
            configured: true,
            authSource: nil,
            credentialType: nil,
            authMethods: [],
            modelCount: 1
        )
        #expect(provider.displayName == "OpenAI Codex")

        let model = ModelSummary(
            provider: "openai-codex",
            id: "gpt-5.6-luna",
            name: "gpt-5.6-luna",
            reasoning: true,
            input: ["text"],
            contextWindow: 1,
            maxTokens: 1,
            available: true
        )
        #expect(model.displayName == "GPT 5.6 Luna")
        #expect(model.displayDescription == "OpenAI Codex / GPT 5.6 Luna")
    }
}
