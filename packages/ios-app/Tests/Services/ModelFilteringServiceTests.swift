import XCTest
@testable import TronMobile

final class ModelFilteringServiceTests: XCTestCase {

    // MARK: - Test Data

    /// Create test models for testing
    private func makeModels() -> [ModelInfo] {
        [
            // Anthropic latest models
            makeModel(id: "claude-opus-4-6", provider: "anthropic"),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-haiku-4-5-20250501", provider: "anthropic"),

            // Anthropic legacy models
            makeModel(id: "claude-sonnet-4-20250514", provider: "anthropic"),
            makeModel(id: "claude-3-5-sonnet-20241022", provider: "anthropic"),
            makeModel(id: "claude-3-haiku-20240307", provider: "anthropic"),

            // OpenAI Codex models
            makeModel(id: "gpt-5.2-codex", provider: "openai-codex"),
            makeModel(id: "gpt-5.1-codex", provider: "openai-codex"),
            makeModel(id: "gpt-5.0-codex", provider: "openai-codex"),

            // Gemini models
            makeModel(id: "gemini-3-pro-preview", provider: "google"),
            makeModel(id: "gemini-3-flash", provider: "google"),
            makeModel(id: "gemini-3-flash-lite", provider: "google"),
            makeModel(id: "gemini-2.5-pro", provider: "google"),
            makeModel(id: "gemini-2.5-flash", provider: "google"),
        ]
    }

    private func makeModel(
        id: String,
        provider: String,
        name: String? = nil,
        contextWindow: Int = 200_000,
        maxOutputTokens: Int? = 16_000
    ) -> ModelInfo {
        // Use JSONDecoder to create ModelInfo since it has no public init
        let json: [String: Any] = [
            "id": id,
            "name": name ?? id,
            "provider": provider,
            "contextWindow": contextWindow,
            "maxOutputTokens": maxOutputTokens as Any
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ModelInfo.self, from: data)
    }

    // MARK: - Categorize Tests

    func test_categorizeModels_separatesAnthropicBy45VsLegacy() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        // Should have Anthropic (Latest), OpenAI Codex (Latest), Gemini 3, Legacy sections
        let anthropicLatest = groups.first { $0.tier == "Anthropic (Latest)" }
        XCTAssertNotNil(anthropicLatest)
        XCTAssertEqual(anthropicLatest?.models.count, 4) // Opus 4.6, Opus 4.5, Sonnet 4.5, Haiku 4.5

        // All should be latest generation models
        anthropicLatest?.models.forEach { model in
            XCTAssertTrue(model.isLatestGeneration, "Expected \(model.id) to be latest generation")
        }
    }

    func test_categorizeModels_separatesCodexByVersion() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        let codexLatest = groups.first { $0.tier == "OpenAI Codex (Latest)" }
        XCTAssertNotNil(codexLatest)
        XCTAssertEqual(codexLatest?.models.count, 1) // Only 5.2

        XCTAssertEqual(codexLatest?.models.first?.id, "gpt-5.2-codex")
    }

    func test_categorizeModels_separatesGeminiByVersion() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        let gemini3 = groups.first { $0.tier == "Gemini 3" }
        XCTAssertNotNil(gemini3)
        XCTAssertEqual(gemini3?.models.count, 3) // Pro, Flash, Flash Lite

        gemini3?.models.forEach { model in
            XCTAssertTrue(model.isGemini3, "Expected \(model.id) to be Gemini 3")
        }
    }

    func test_categorizeModels_groupsLegacyTogether() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        let legacy = groups.first { $0.tier == "Legacy" }
        XCTAssertNotNil(legacy)

        // Should contain: legacy Anthropic + Codex 5.1/5.0 + Gemini 2.5
        let legacyModels = legacy!.models
        XCTAssertTrue(legacyModels.contains { $0.id.contains("sonnet-4-20250514") })
        XCTAssertTrue(legacyModels.contains { $0.id.contains("5.1") })
        XCTAssertTrue(legacyModels.contains { $0.id.contains("gemini-2.5") })
    }

    func test_categorizeModels_handlesEmptyArray() {
        let groups = ModelFilteringService.categorize([])
        XCTAssertTrue(groups.isEmpty)
    }

    func test_categorizeModels_handlesUnknownProvider() {
        let models = [makeModel(id: "unknown-model-v1", provider: "unknown-provider")]
        let groups = ModelFilteringService.categorize(models)

        // Unknown providers should go to legacy or be handled gracefully
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.tier, "Legacy")
    }

    // MARK: - Filter Tests

    func test_filterLatest_returnsOnlyLatestModels() {
        let models = makeModels()
        let latest = ModelFilteringService.filterLatest(models)

        // Should include: Anthropic 4.5, Codex 5.2, Gemini 3
        XCTAssertEqual(latest.count, 8) // 4 + 1 + 3

        latest.forEach { model in
            let isLatest = model.isLatestGeneration ||
                          (model.isCodex && model.id.contains("5.2")) ||
                          model.isGemini3
            XCTAssertTrue(isLatest, "Expected \(model.id) to be latest")
        }
    }

    func test_filterLegacy_returnsOnlyLegacyModels() {
        let models = makeModels()
        let legacy = ModelFilteringService.filterLegacy(models)

        // Should exclude: Anthropic 4.5, Codex 5.2, Gemini 3
        legacy.forEach { model in
            XCTAssertFalse(model.isLatestGeneration && model.isAnthropic)
            XCTAssertFalse(model.isCodex && model.id.contains("5.2"))
            XCTAssertFalse(model.isGemini3)
        }
    }

    // MARK: - Sort Tests

    func test_sortByTier_anthropicOpusFirst() {
        let models = [
            makeModel(id: "claude-haiku-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic"),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "claude-opus-4-5-20250501")
        XCTAssertEqual(sorted[1].id, "claude-sonnet-4-5-20250501")
        XCTAssertEqual(sorted[2].id, "claude-haiku-4-5-20250501")
    }

    func test_sortByTier_codex52BeforeCodex51() {
        let models = [
            makeModel(id: "gpt-5.0-codex", provider: "openai-codex"),
            makeModel(id: "gpt-5.2-codex", provider: "openai-codex"),
            makeModel(id: "gpt-5.1-codex", provider: "openai-codex"),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "gpt-5.2-codex")
        XCTAssertEqual(sorted[1].id, "gpt-5.1-codex")
        XCTAssertEqual(sorted[2].id, "gpt-5.0-codex")
    }

    func test_sortByTier_geminiProBeforeFlash() {
        let models = [
            makeModel(id: "gemini-3-flash-lite", provider: "google"),
            makeModel(id: "gemini-3-pro-preview", provider: "google"),
            makeModel(id: "gemini-3-flash", provider: "google"),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "gemini-3-pro-preview")
        XCTAssertEqual(sorted[1].id, "gemini-3-flash")
        XCTAssertEqual(sorted[2].id, "gemini-3-flash-lite")
    }

    func test_sortByTier_newerVersionFirst_sameTier() {
        let models = [
            makeModel(id: "claude-sonnet-3-5-20241022", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-20250514", provider: "anthropic"),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        // 4.5 > 4 > 3.5 (all sonnet)
        XCTAssertEqual(sorted[0].id, "claude-sonnet-4-5-20250501")
        XCTAssertEqual(sorted[1].id, "claude-sonnet-4-20250514")
        XCTAssertEqual(sorted[2].id, "claude-sonnet-3-5-20241022")
    }

    func test_sortByTier_opus46BeforeOpus45() {
        let models = [
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-opus-4-6", provider: "anthropic"),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "claude-opus-4-6")
        XCTAssertEqual(sorted[1].id, "claude-opus-4-5-20250501")
    }

    func test_categorizeModels_opus46InLatestSection() {
        let models = [
            makeModel(id: "claude-opus-4-6", provider: "anthropic"),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-20250514", provider: "anthropic"),
        ]

        let groups = ModelFilteringService.categorize(models)

        let latest = groups.first { $0.tier == "Anthropic (Latest)" }
        XCTAssertNotNil(latest)
        XCTAssertTrue(latest!.models.contains { $0.id == "claude-opus-4-6" })
    }

    // MARK: - Deduplicate Tests

    func test_uniqueByFormattedName_removesDuplicates() {
        // Two models with same formatted name but different IDs
        let models = [
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-5-20250601", provider: "anthropic"),
        ]

        let unique = ModelFilteringService.uniqueByFormattedName(models)

        XCTAssertEqual(unique.count, 1)
    }

    func test_uniqueByFormattedName_preservesFirst() {
        // Two Sonnet 4.5 models with different dates but same formatted name
        let models = [
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-5-20250601", provider: "anthropic"),
        ]

        let unique = ModelFilteringService.uniqueByFormattedName(models)

        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(unique.first?.id, "claude-sonnet-4-5-20250501")
    }

    func test_uniqueByFormattedName_preservesAllWhenNoDuplicates() {
        let models = [
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic"),
            makeModel(id: "claude-haiku-4-5-20250501", provider: "anthropic"),
        ]

        let unique = ModelFilteringService.uniqueByFormattedName(models)

        XCTAssertEqual(unique.count, 3)
    }

    // MARK: - Integration Tests

    func test_categorize_producesConsistentOrder() {
        let models = makeModels()

        // Run twice, should produce same order
        let groups1 = ModelFilteringService.categorize(models)
        let groups2 = ModelFilteringService.categorize(models)

        XCTAssertEqual(groups1.count, groups2.count)
        for (g1, g2) in zip(groups1, groups2) {
            XCTAssertEqual(g1.tier, g2.tier)
            XCTAssertEqual(g1.models.map(\.id), g2.models.map(\.id))
        }
    }
}
