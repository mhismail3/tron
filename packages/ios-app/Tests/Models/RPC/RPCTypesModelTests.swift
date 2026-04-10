import Testing
import Foundation
@testable import TronMobile

@Suite("ModelInfo Computed Properties Tests")
struct ModelInfoComputedTests {

    // MARK: - Helpers

    private func makeModel(
        id: String = "claude-sonnet-4-6-20250514",
        name: String = "Sonnet 4.6",
        provider: String = "anthropic",
        contextWindow: Int = 200_000,
        tier: String? = "sonnet",
        isLegacy: Bool? = nil,
        isDeprecated: Bool? = nil,
        family: String? = "Claude 4.6",
        maxOutput: Int? = nil,
        maxOutputTokens: Int? = nil,
        inputCostPerMillion: Double? = nil,
        outputCostPerMillion: Double? = nil
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            name: name,
            provider: provider,
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            tier: tier,
            isLegacy: isLegacy,
            isDeprecated: isDeprecated,
            family: family,
            maxOutput: maxOutput,
            inputCostPerMillion: inputCostPerMillion,
            outputCostPerMillion: outputCostPerMillion
        )
    }

    // MARK: - Pricing Format

    @Test("pricing both nil returns nil")
    func pricingBothNil() {
        let m = makeModel()
        #expect(m.formattedPricing == nil)
    }

    @Test("pricing sub-dollar uses 2 decimal places")
    func pricingSubDollar() {
        let m = makeModel(inputCostPerMillion: 0.25, outputCostPerMillion: 0.75)
        #expect(m.formattedPricing == "$0.25/M in · $0.75/M out")
    }

    @Test("pricing dollar and above uses integer")
    func pricingDollarPlus() {
        let m = makeModel(inputCostPerMillion: 3, outputCostPerMillion: 15)
        #expect(m.formattedPricing == "$3/M in · $15/M out")
    }

    @Test("pricing exactly 1.0 uses integer")
    func pricingExactlyOne() {
        let m = makeModel(inputCostPerMillion: 1.0, outputCostPerMillion: 1.0)
        #expect(m.formattedPricing == "$1/M in · $1/M out")
    }

    @Test("pricing zero values")
    func pricingZero() {
        let m = makeModel(inputCostPerMillion: 0, outputCostPerMillion: 0)
        #expect(m.formattedPricing == "$0.00/M in · $0.00/M out")
    }

    // MARK: - Max Output Format

    @Test("maxOutput 128K")
    func maxOutput128K() {
        let m = makeModel(maxOutput: 128_000)
        #expect(m.formattedMaxOutput == "128K output")
    }

    @Test("maxOutput 1M")
    func maxOutput1M() {
        let m = makeModel(maxOutput: 1_000_000)
        #expect(m.formattedMaxOutput == "1M output")
    }

    @Test("maxOutput sub-1K")
    func maxOutputSmall() {
        let m = makeModel(maxOutput: 500)
        #expect(m.formattedMaxOutput == "500 output")
    }

    @Test("maxOutput nil returns nil")
    func maxOutputNil() {
        let m = makeModel()
        #expect(m.formattedMaxOutput == nil)
    }

    @Test("maxOutput falls back to maxOutputTokens")
    func maxOutputFallback() {
        let m = makeModel(maxOutputTokens: 64_000)
        #expect(m.formattedMaxOutput == "64K output")
    }

    // MARK: - Context Window Format

    @Test("context window 200K")
    func contextWindow200K() {
        let m = makeModel(contextWindow: 200_000)
        #expect(m.formattedContextWindow == "200K context")
    }

    @Test("context window 1M")
    func contextWindow1M() {
        let m = makeModel(contextWindow: 1_000_000)
        #expect(m.formattedContextWindow == "1M context")
    }

    @Test("context window small")
    func contextWindowSmall() {
        let m = makeModel(contextWindow: 512)
        #expect(m.formattedContextWindow == "512 context")
    }

    // MARK: - Display Names

    @Test("displayName for Anthropic model")
    func displayNameAnthropic() {
        let m = makeModel(name: "Opus 4.6", provider: "anthropic")
        #expect(m.displayName == "Claude Opus 4.6")
    }

    @Test("displayName for non-Anthropic model")
    func displayNameOther() {
        let m = makeModel(name: "GPT-5.3", provider: "openai")
        #expect(m.displayName == "GPT-5.3")
    }

    @Test("formattedModelName matches displayName")
    func formattedModelNameMatchesDisplayName() {
        let m = makeModel()
        #expect(m.displayName == m.formattedModelName)
    }

    @Test("shortName Anthropic with tier")
    func shortNameWithTier() {
        let m = makeModel(tier: "sonnet")
        #expect(m.shortName == "Sonnet")
    }

    @Test("shortName Anthropic without tier")
    func testShortNameWithoutTier() {
        let m = makeModel(tier: nil)
        #expect(m.shortName == "Sonnet 4.6")
    }

    @Test("shortName non-Anthropic")
    func testShortNameNonAnthropic() {
        let m = makeModel(name: "GPT-5.3", provider: "openai", tier: "gpt5")
        #expect(m.shortName == "GPT-5.3")
    }

    // MARK: - Provider Detection

    @Test("isAnthropic")
    func testIsAnthropic() {
        #expect(makeModel(provider: "anthropic").isAnthropic == true)
        #expect(makeModel(provider: "google").isAnthropic == false)
    }

    @Test("isCodex")
    func testIsCodex() {
        #expect(makeModel(provider: "openai-codex").isCodex == true)
        #expect(makeModel(provider: "openai").isCodex == false)
    }

    @Test("isGemini by provider")
    func testIsGeminiByProvider() {
        #expect(makeModel(provider: "google").isGemini == true)
    }

    @Test("isGemini by id")
    func testIsGeminiById() {
        #expect(makeModel(id: "gemini-3-pro", provider: "other").isGemini == true)
        #expect(makeModel(id: "GEMINI-flash", provider: "other").isGemini == true)
    }

    @Test("isMiniMax")
    func testIsMiniMax() {
        #expect(makeModel(provider: "minimax").isMiniMax == true)
    }

    @Test("isKimi")
    func testIsKimi() {
        #expect(makeModel(provider: "kimi").isKimi == true)
    }

    // MARK: - isGemini3

    @Test("isGemini3 with Gemini 3 family")
    func testIsGemini3WithFamily() {
        let m = makeModel(provider: "google", family: "Gemini 3 Pro")
        #expect(m.isGemini3 == true)
    }

    @Test("isGemini3 with nil family")
    func testIsGemini3NilFamily() {
        let m = makeModel(provider: "google", family: nil)
        #expect(m.isGemini3 == false)
    }

    @Test("isGemini3 with empty family")
    func testIsGemini3EmptyFamily() {
        let m = makeModel(provider: "google", family: "")
        #expect(m.isGemini3 == false)
    }

    @Test("isGemini3 with Gemini 2 family")
    func testIsGemini3OlderFamily() {
        let m = makeModel(provider: "google", family: "Gemini 2")
        #expect(m.isGemini3 == false)
    }

    @Test("isGemini3 false for non-Gemini provider")
    func testIsGemini3NonGemini() {
        let m = makeModel(provider: "anthropic", family: "Gemini 3 Pro")
        #expect(m.isGemini3 == false)
    }

    // MARK: - Lifecycle Flags

    @Test("isLatestGeneration nil isLegacy returns true")
    func testLatestGenNil() { #expect(makeModel(isLegacy: nil).isLatestGeneration == true) }

    @Test("isLatestGeneration false isLegacy returns true")
    func testLatestGenFalse() { #expect(makeModel(isLegacy: false).isLatestGeneration == true) }

    @Test("isLatestGeneration true isLegacy returns false")
    func testLatestGenTrue() { #expect(makeModel(isLegacy: true).isLatestGeneration == false) }

    @Test("isDeprecatedModel nil returns false")
    func testDeprecatedNil() { #expect(makeModel(isDeprecated: nil).isDeprecatedModel == false) }

    @Test("isDeprecatedModel true returns true")
    func testDeprecatedTrue() { #expect(makeModel(isDeprecated: true).isDeprecatedModel == true) }

    @Test("isPreview")
    func testIsPreview() {
        #expect(makeModel(id: "claude-preview-2026").isPreview == true)
        #expect(makeModel(id: "claude-sonnet-4-6").isPreview == false)
    }
}
