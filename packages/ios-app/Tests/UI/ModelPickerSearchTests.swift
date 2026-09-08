import Testing
@testable import TronMobile

@Suite("Model picker search")
struct ModelPickerSearchTests {
    @Test("shared picker filters provider, id, and display name")
    func filtersModels() {
        let models = [
            ModelSummary(provider: "alpha", id: "reasoning", name: "Alpha Reasoner", reasoning: true, input: ["text"], contextWindow: 1_000, maxTokens: 100, available: true),
            ModelSummary(provider: "beta", id: "fast", name: "Beta Fast", reasoning: false, input: ["text"], contextWindow: 1_000, maxTokens: 100, available: true),
        ]
        #expect(ModelPickerSearchPolicy.filtered(models, query: "beta").map(\.id) == ["fast"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "reasoning").map(\.id) == ["reasoning"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "").count == 2)
    }

    @Test("search close guard preserves an active query lifecycle")
    func closeGuard() {
        #expect(ModelPickerSearchPolicy.shouldClose(showingSearch: true, query: "") == true)
        #expect(ModelPickerSearchPolicy.shouldClose(showingSearch: false, query: "beta") == true)
        #expect(ModelPickerSearchPolicy.shouldClose(showingSearch: false, query: "") == false)
    }
}
