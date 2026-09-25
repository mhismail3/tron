import Testing
@testable import TronMobile

@Suite("Model picker search")
struct ModelPickerSearchTests {
    @Test("shared picker filters provider, id, and display name")
    func filtersModels() {
        let models = [
            ModelSummary(provider: "alpha", id: "reasoning", name: "Alpha Reasoner", reasoning: true, input: ["text"], contextWindow: 1_000, maxTokens: 100, available: true),
            ModelSummary(provider: "beta", id: "fast", name: "Beta Fast", reasoning: false, input: ["text"], contextWindow: 1_000, maxTokens: 100, available: true),
            ModelSummary(provider: "anthropic", id: "claude-opus-4-5", name: "Claude Opus 4.5 (latest)", reasoning: true, input: ["text"], contextWindow: 200_000, maxTokens: 32_000, available: true),
            ModelSummary(provider: "anthropic", id: "claude-opus-4-5-20251101", name: "Claude Opus 4.5", reasoning: true, input: ["text"], contextWindow: 200_000, maxTokens: 32_000, available: true),
        ]
        #expect(ModelPickerSearchPolicy.filtered(models, query: "beta").map(\.id) == ["fast"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "reasoning").map(\.id) == ["reasoning"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "20251101").map(\.id) == ["claude-opus-4-5-20251101"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "latest alias").map(\.id) == ["claude-opus-4-5"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "").count == 4)
    }
}
