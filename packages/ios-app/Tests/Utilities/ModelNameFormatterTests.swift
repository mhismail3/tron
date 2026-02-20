import XCTest
@testable import TronMobile

final class ModelNameFormatterTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // Clear server cache between tests
        ModelNameFormatter.updateFromServer([])
    }

    // MARK: - Server Cache Tests

    func testServerCacheLookup_short() {
        let model = makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic", tier: "opus")
        ModelNameFormatter.updateFromServer([model])

        XCTAssertEqual(ModelNameFormatter.format("claude-opus-4-6", style: .short), "Opus 4.6")
    }

    func testServerCacheLookup_full_anthropic() {
        let model = makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic", tier: "opus")
        ModelNameFormatter.updateFromServer([model])

        XCTAssertEqual(ModelNameFormatter.format("claude-opus-4-6", style: .full), "Claude Opus 4.6")
    }

    func testServerCacheLookup_full_nonAnthropic() {
        let model = makeModel(id: "gemini-3-pro-preview", name: "Gemini 3 Pro", provider: "google", tier: "pro")
        ModelNameFormatter.updateFromServer([model])

        XCTAssertEqual(ModelNameFormatter.format("gemini-3-pro-preview", style: .full), "Gemini 3 Pro")
    }

    func testServerCacheLookup_tierOnly_anthropic() {
        let model = makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic", tier: "opus")
        ModelNameFormatter.updateFromServer([model])

        XCTAssertEqual(ModelNameFormatter.format("claude-opus-4-6", style: .tierOnly), "Opus")
    }

    func testServerCacheLookup_tierOnly_nonAnthropic() {
        let model = makeModel(id: "gpt-5.3-codex", name: "GPT-5.3 Codex", provider: "openai-codex")
        ModelNameFormatter.updateFromServer([model])

        XCTAssertEqual(ModelNameFormatter.format("gpt-5.3-codex", style: .tierOnly), "GPT-5.3 Codex")
    }

    func testServerCacheLookup_compact() {
        let model = makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic")
        ModelNameFormatter.updateFromServer([model])

        XCTAssertEqual(ModelNameFormatter.format("claude-opus-4-6", style: .compact), "opus-4.6")
    }

    // MARK: - Fallback Tests (no server cache)

    func testFallback_claudeModel() {
        // No server cache → falls back to heuristic parsing
        XCTAssertEqual(ModelNameFormatter.format("claude-opus-4-6", style: .short), "Opus 4.6")
        XCTAssertEqual(ModelNameFormatter.format("claude-opus-4-6", style: .full), "Claude Opus 4.6")
    }

    func testFallback_codexModel() {
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.3-codex", style: .short), "GPT-5.3 Codex")
    }

    func testFallback_geminiModel() {
        XCTAssertEqual(ModelNameFormatter.format("gemini-3-pro-preview", style: .short), "Gemini 3 Pro")
    }

    // MARK: - Cache Population

    func testUpdateFromServer_populatesCache() {
        XCTAssertTrue(ModelNameFormatter.serverModels.isEmpty)

        let models = [
            makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic"),
            makeModel(id: "gpt-5.3-codex", name: "GPT-5.3 Codex", provider: "openai-codex"),
        ]
        ModelNameFormatter.updateFromServer(models)

        XCTAssertEqual(ModelNameFormatter.serverModels.count, 2)
        XCTAssertEqual(ModelNameFormatter.serverModels["claude-opus-4-6"]?.name, "Opus 4.6")
    }

    func testUpdateFromServer_replacesCache() {
        let models1 = [makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic")]
        ModelNameFormatter.updateFromServer(models1)
        XCTAssertEqual(ModelNameFormatter.serverModels.count, 1)

        let models2 = [makeModel(id: "gpt-5.3-codex", name: "GPT-5.3 Codex", provider: "openai-codex")]
        ModelNameFormatter.updateFromServer(models2)
        XCTAssertEqual(ModelNameFormatter.serverModels.count, 1)
        XCTAssertNil(ModelNameFormatter.serverModels["claude-opus-4-6"])
    }

    // MARK: - formatModelDisplayName

    func testFormatModelDisplayName_usesCache() {
        let model = makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic")
        ModelNameFormatter.updateFromServer([model])

        XCTAssertEqual(formatModelDisplayName("claude-opus-4-6"), "Opus 4.6")
    }

    func testFormatModelDisplayName_fallback() {
        // No cache → falls back to shortModelName heuristic
        let result = formatModelDisplayName("claude-sonnet-4-5-20250929")
        XCTAssertEqual(result, "Sonnet 4.5")
    }

    // MARK: - Helpers

    private func makeModel(
        id: String,
        name: String,
        provider: String,
        tier: String? = nil
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            name: name,
            provider: provider,
            contextWindow: 200_000,
            tier: tier
        )
    }
}
