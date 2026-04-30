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

    func testFallback_gptModels() {
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.5", style: .short), "GPT-5.5")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.5-2026-04-23", style: .short), "GPT-5.5")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.4", style: .short), "GPT-5.4")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.4-pro", style: .short), "GPT-5.4 Pro")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.4-mini", style: .short), "GPT-5.4 Mini")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.4-nano", style: .short), "GPT-5.4 Nano")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.3-codex", style: .short), "GPT-5.3")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.2", style: .short), "GPT-5.2")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.3-codex-spark", style: .short), "GPT-5.3 Spark")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.1-codex-max", style: .short), "GPT-5.1 Max")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.1-codex-mini", style: .short), "GPT-5.1 Mini")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5.3-chat-latest", style: .short), "GPT-5.3 Chat")
        XCTAssertEqual(ModelNameFormatter.format("gpt-5-pro", style: .short), "GPT-5 Pro")
        XCTAssertEqual(ModelNameFormatter.format("gpt-4.1", style: .short), "GPT-4.1")
        XCTAssertEqual(ModelNameFormatter.format("gpt-4.1-mini", style: .short), "GPT-4.1 Mini")
        XCTAssertEqual(ModelNameFormatter.format("gpt-4o", style: .short), "GPT-4o")
        XCTAssertEqual(ModelNameFormatter.format("gpt-4.5-preview", style: .short), "GPT-4.5 Preview")
        XCTAssertEqual(ModelNameFormatter.format("gpt-4-turbo", style: .short), "GPT-4 Turbo")
        XCTAssertEqual(ModelNameFormatter.format("gpt-3.5-turbo", style: .short), "GPT-3.5 Turbo")
        XCTAssertEqual(ModelNameFormatter.format("gpt-oss-120b", style: .short), "GPT-OSS 120B")
        XCTAssertEqual(ModelNameFormatter.format("chatgpt-4o-latest", style: .short), "ChatGPT-4o")
        XCTAssertEqual(ModelNameFormatter.format("o3", style: .short), "o3")
        XCTAssertEqual(ModelNameFormatter.format("o4-mini", style: .short), "o4 Mini")
        XCTAssertEqual(ModelNameFormatter.format("o1-preview", style: .short), "o1 Preview")
    }

    func testFallback_geminiModel() {
        XCTAssertEqual(ModelNameFormatter.format("gemini-3-pro-preview", style: .short), "Gemini 3 Pro")
        XCTAssertEqual(ModelNameFormatter.format("gemini-3.1-pro-preview", style: .short), "Gemini 3.1 Pro")
        XCTAssertEqual(ModelNameFormatter.format("gemini-3-flash-preview", style: .short), "Gemini 3 Flash")
        XCTAssertEqual(ModelNameFormatter.format("gemini-3.1-flash-lite-preview", style: .short), "Gemini 3.1 Flash Lite")
        XCTAssertEqual(ModelNameFormatter.format("gemini-2.5-pro", style: .short), "Gemini 2.5 Pro")
        XCTAssertEqual(ModelNameFormatter.format("gemini-2.5-flash", style: .short), "Gemini 2.5 Flash")
        XCTAssertEqual(ModelNameFormatter.format("gemini-2.5-flash-lite", style: .short), "Gemini 2.5 Flash Lite")
    }

    func testFallback_minimaxModel() {
        XCTAssertEqual(ModelNameFormatter.format("MiniMax-M2.7", style: .short), "MiniMax M2.7")
        XCTAssertEqual(ModelNameFormatter.format("MiniMax-M2.7-highspeed", style: .short), "MiniMax M2.7 HS")
        XCTAssertEqual(ModelNameFormatter.format("MiniMax-M2.5", style: .short), "MiniMax M2.5")
        XCTAssertEqual(ModelNameFormatter.format("MiniMax-M2", style: .short), "MiniMax M2")
    }

    func testFallback_kimiModel() {
        XCTAssertEqual(ModelNameFormatter.format("kimi-k2.5", style: .short), "Kimi K2.5")
        XCTAssertEqual(ModelNameFormatter.format("kimi-k2-turbo-preview", style: .short), "Kimi K2 Turbo")
        XCTAssertEqual(ModelNameFormatter.format("kimi-k2-thinking", style: .short), "Kimi K2 Think")
        XCTAssertEqual(ModelNameFormatter.format("kimi-k2-thinking-turbo", style: .short), "Kimi K2 Think Turbo")
        XCTAssertEqual(ModelNameFormatter.format("moonshot-v1-128k", style: .short), "Moonshot V1 128K")
    }

    func testFallback_ollamaModel() {
        XCTAssertEqual(ModelNameFormatter.format("gemma4:e4b", style: .short), "Gemma 4 E4B")
        XCTAssertEqual(ModelNameFormatter.format("gemma4:26b", style: .short), "Gemma 4 26B")
    }

    func testProviderPrefix_stripped() {
        XCTAssertEqual(ModelNameFormatter.format("openai/gpt-5.4", style: .short), "GPT-5.4")
        XCTAssertEqual(ModelNameFormatter.format("google/gemini-2.5-flash", style: .short), "Gemini 2.5 Flash")
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
        tier: String = "sonnet"
    ) -> ModelInfo {
        // I8: tier/isLegacy/supportsThinking/Images/Documents are required.
        ModelInfo(
            id: id,
            name: name,
            provider: provider,
            contextWindow: 200_000,
            supportsThinking: false,
            supportsImages: false,
            supportsDocuments: false,
            tier: tier,
            isLegacy: false
        )
    }
}
