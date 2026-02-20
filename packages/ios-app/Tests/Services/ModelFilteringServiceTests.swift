import XCTest
@testable import TronMobile

final class ModelFilteringServiceTests: XCTestCase {

    // MARK: - Test Data

    /// Create test models for testing
    private func makeModels() -> [ModelInfo] {
        [
            // Anthropic latest models
            makeModel(id: "claude-opus-4-6", provider: "anthropic", name: "Opus 4.6",
                      family: "Claude 4.6", tier: "opus", isLegacy: false, sortOrder: 0),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic", name: "Opus 4.5",
                      family: "Claude 4.5", tier: "opus", isLegacy: false, sortOrder: 2),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", name: "Sonnet 4.5",
                      family: "Claude 4.5", tier: "sonnet", isLegacy: false, sortOrder: 3),
            makeModel(id: "claude-haiku-4-5-20250501", provider: "anthropic", name: "Haiku 4.5",
                      family: "Claude 4.5", tier: "haiku", isLegacy: false, sortOrder: 4),

            // Anthropic legacy models
            makeModel(id: "claude-sonnet-4-20250514", provider: "anthropic", name: "Sonnet 4",
                      family: "Claude 4", tier: "sonnet", isLegacy: true, sortOrder: 7),
            makeModel(id: "claude-3-5-sonnet-20241022", provider: "anthropic", name: "Sonnet 3.5",
                      family: "Claude 3.5", tier: "sonnet", isLegacy: true, sortOrder: 10),
            makeModel(id: "claude-3-haiku-20240307", provider: "anthropic", name: "Haiku 3",
                      family: "Claude 3", tier: "haiku", isLegacy: true, sortOrder: 9),

            // OpenAI Codex models
            makeModel(id: "gpt-5.3-codex", provider: "openai-codex", name: "GPT-5.3 Codex",
                      family: "GPT-5.3", isLegacy: false, sortOrder: 0),
            makeModel(id: "gpt-5.2-codex", provider: "openai-codex", name: "GPT-5.2 Codex",
                      family: "GPT-5.2", isLegacy: false, sortOrder: 2),
            makeModel(id: "gpt-5.1-codex", provider: "openai-codex", name: "GPT-5.1 Codex",
                      family: "GPT-5.1", isLegacy: false, sortOrder: 3),
            makeModel(id: "gpt-5.0-codex", provider: "openai-codex", name: "GPT-5.0 Codex",
                      family: "GPT-5.0", isLegacy: false, sortOrder: 4),

            // Gemini models
            makeModel(id: "gemini-3-pro-preview", provider: "google", name: "Gemini 3 Pro",
                      family: "Gemini 3", tier: "pro", isLegacy: false, sortOrder: 0),
            makeModel(id: "gemini-3-flash", provider: "google", name: "Gemini 3 Flash",
                      family: "Gemini 3", tier: "flash", isLegacy: false, sortOrder: 1),
            makeModel(id: "gemini-3-flash-lite", provider: "google", name: "Gemini 3 Flash Lite",
                      family: "Gemini 3", tier: "flash-lite", isLegacy: false, sortOrder: 2),
            makeModel(id: "gemini-2.5-pro", provider: "google", name: "Gemini 2.5 Pro",
                      family: "Gemini 2.5", tier: "pro", isLegacy: false, sortOrder: 3),
            makeModel(id: "gemini-2.5-flash", provider: "google", name: "Gemini 2.5 Flash",
                      family: "Gemini 2.5", tier: "flash", isLegacy: false, sortOrder: 4),
        ]
    }

    private func makeModel(
        id: String,
        provider: String,
        name: String? = nil,
        contextWindow: Int = 200_000,
        maxOutputTokens: Int? = 16_000,
        family: String? = nil,
        tier: String? = nil,
        maxOutput: Int? = nil,
        description: String? = nil,
        inputCostPerMillion: Double? = nil,
        outputCostPerMillion: Double? = nil,
        recommended: Bool? = nil,
        isLegacy: Bool? = nil,
        sortOrder: Int? = nil
    ) -> ModelInfo {
        var json: [String: Any] = [
            "id": id,
            "name": name ?? id,
            "provider": provider,
            "contextWindow": contextWindow,
            "maxOutputTokens": maxOutputTokens as Any
        ]
        if let family { json["family"] = family }
        if let tier { json["tier"] = tier }
        if let maxOutput { json["maxOutput"] = maxOutput }
        if let description { json["description"] = description }
        if let inputCostPerMillion { json["inputCostPerMillion"] = inputCostPerMillion }
        if let outputCostPerMillion { json["outputCostPerMillion"] = outputCostPerMillion }
        if let recommended { json["recommended"] = recommended }
        if let isLegacy { json["isLegacy"] = isLegacy }
        if let sortOrder { json["sortOrder"] = sortOrder }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ModelInfo.self, from: data)
    }

    // MARK: - Categorize Tests

    func test_categorizeModels_separatesAnthropicByLegacyFlag() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        let anthropicLatest = groups.first { $0.tier == "Anthropic (Latest)" }
        XCTAssertNotNil(anthropicLatest)
        XCTAssertEqual(anthropicLatest?.models.count, 4) // Opus 4.6, Opus 4.5, Sonnet 4.5, Haiku 4.5

        anthropicLatest?.models.forEach { model in
            XCTAssertTrue(model.isLatestGeneration, "Expected \(model.id) to be latest generation")
        }
    }

    func test_categorizeModels_separatesCodexByLegacyFlag() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        let codexLatest = groups.first { $0.tier == "OpenAI Codex (Latest)" }
        XCTAssertNotNil(codexLatest)
        // All OpenAI models in test data are isLegacy: false
        XCTAssertEqual(codexLatest?.models.count, 4)
    }

    func test_categorizeModels_separatesGeminiByFamily() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        // All Gemini models in test data are isLegacy: false
        let geminiLatest = groups.first { $0.tier.contains("Gemini") }
        XCTAssertNotNil(geminiLatest)
        XCTAssertEqual(geminiLatest?.models.count, 5)
    }

    func test_categorizeModels_groupsLegacyTogether() {
        let models = makeModels()
        let groups = ModelFilteringService.categorize(models)

        let legacy = groups.first { $0.tier == "Legacy" }
        XCTAssertNotNil(legacy)

        let legacyModels = legacy!.models
        XCTAssertTrue(legacyModels.contains { $0.id.contains("sonnet-4-20250514") })
        XCTAssertTrue(legacyModels.contains { $0.id.contains("3-5-sonnet") })
    }

    func test_categorizeModels_handlesEmptyArray() {
        let groups = ModelFilteringService.categorize([])
        XCTAssertTrue(groups.isEmpty)
    }

    func test_categorizeModels_handlesUnknownProvider() {
        let models = [makeModel(id: "unknown-model-v1", provider: "unknown-provider")]
        let groups = ModelFilteringService.categorize(models)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.tier, "Legacy")
    }

    // MARK: - Filter Tests

    func test_filterLatest_returnsOnlyNonLegacyModels() {
        let models = makeModels()
        let latest = ModelFilteringService.filterLatest(models)

        latest.forEach { model in
            XCTAssertFalse(model.isLegacy ?? false, "Expected \(model.id) to not be legacy")
        }
    }

    func test_filterLegacy_returnsOnlyLegacyModels() {
        let models = makeModels()
        let legacy = ModelFilteringService.filterLegacy(models)

        legacy.forEach { model in
            XCTAssertTrue(model.isLegacy ?? false, "Expected \(model.id) to be legacy")
        }
    }

    // MARK: - Sort Tests

    func test_sortByTier_usesSortOrder() {
        let models = [
            makeModel(id: "claude-haiku-4-5-20250501", provider: "anthropic",
                      isLegacy: false, sortOrder: 4),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic",
                      isLegacy: false, sortOrder: 2),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic",
                      isLegacy: false, sortOrder: 3),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "claude-opus-4-5-20250501")
        XCTAssertEqual(sorted[1].id, "claude-sonnet-4-5-20250501")
        XCTAssertEqual(sorted[2].id, "claude-haiku-4-5-20250501")
    }

    func test_sortByTier_codexBySortOrder() {
        let models = [
            makeModel(id: "gpt-5.0-codex", provider: "openai-codex", sortOrder: 4),
            makeModel(id: "gpt-5.3-codex", provider: "openai-codex", sortOrder: 0),
            makeModel(id: "gpt-5.2-codex", provider: "openai-codex", sortOrder: 2),
            makeModel(id: "gpt-5.1-codex", provider: "openai-codex", sortOrder: 3),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "gpt-5.3-codex")
        XCTAssertEqual(sorted[1].id, "gpt-5.2-codex")
        XCTAssertEqual(sorted[2].id, "gpt-5.1-codex")
        XCTAssertEqual(sorted[3].id, "gpt-5.0-codex")
    }

    func test_sortByTier_geminiBySortOrder() {
        let models = [
            makeModel(id: "gemini-3-flash-lite", provider: "google", sortOrder: 2),
            makeModel(id: "gemini-3-pro-preview", provider: "google", sortOrder: 0),
            makeModel(id: "gemini-3-flash", provider: "google", sortOrder: 1),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "gemini-3-pro-preview")
        XCTAssertEqual(sorted[1].id, "gemini-3-flash")
        XCTAssertEqual(sorted[2].id, "gemini-3-flash-lite")
    }

    func test_sortByTier_opus46BeforeOpus45() {
        let models = [
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic", sortOrder: 2),
            makeModel(id: "claude-opus-4-6", provider: "anthropic", sortOrder: 0),
        ]

        let sorted = ModelFilteringService.sortByTier(models)

        XCTAssertEqual(sorted[0].id, "claude-opus-4-6")
        XCTAssertEqual(sorted[1].id, "claude-opus-4-5-20250501")
    }

    func test_categorizeModels_opus46InLatestSection() {
        let models = [
            makeModel(id: "claude-opus-4-6", provider: "anthropic", isLegacy: false, sortOrder: 0),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic", isLegacy: false, sortOrder: 2),
            makeModel(id: "claude-sonnet-4-20250514", provider: "anthropic", isLegacy: true, sortOrder: 7),
        ]

        let groups = ModelFilteringService.categorize(models)

        let latest = groups.first { $0.tier == "Anthropic (Latest)" }
        XCTAssertNotNil(latest)
        XCTAssertTrue(latest!.models.contains { $0.id == "claude-opus-4-6" })
    }

    // MARK: - Deduplicate Tests

    func test_uniqueByFormattedName_removesDuplicates() {
        let models = [
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", name: "Sonnet 4.5"),
            makeModel(id: "claude-sonnet-4-5-20250601", provider: "anthropic", name: "Sonnet 4.5"),
        ]

        let unique = ModelFilteringService.uniqueByFormattedName(models)

        XCTAssertEqual(unique.count, 1)
    }

    func test_uniqueByFormattedName_preservesFirst() {
        let models = [
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", name: "Sonnet 4.5"),
            makeModel(id: "claude-sonnet-4-5-20250601", provider: "anthropic", name: "Sonnet 4.5"),
        ]

        let unique = ModelFilteringService.uniqueByFormattedName(models)

        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(unique.first?.id, "claude-sonnet-4-5-20250501")
    }

    func test_uniqueByFormattedName_preservesAllWhenNoDuplicates() {
        let models = [
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic", name: "Opus 4.5"),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", name: "Sonnet 4.5"),
            makeModel(id: "claude-haiku-4-5-20250501", provider: "anthropic", name: "Haiku 4.5"),
        ]

        let unique = ModelFilteringService.uniqueByFormattedName(models)

        XCTAssertEqual(unique.count, 3)
    }

    // MARK: - organizeByProviderFamily Tests

    func test_organizeByProviderFamily_groups3Providers() {
        let models = makeModels()
        let groups = ModelFilteringService.organizeByProviderFamily(models)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].id, "anthropic")
        XCTAssertEqual(groups[1].id, "openai-codex")
        XCTAssertEqual(groups[2].id, "google")
    }

    func test_organizeByProviderFamily_groupsByFamily() {
        let models = [
            makeModel(id: "claude-opus-4-6", provider: "anthropic", family: "Claude 4.6", sortOrder: 0),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic", family: "Claude 4.5", sortOrder: 2),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", family: "Claude 4.5", sortOrder: 3),
        ]
        let groups = ModelFilteringService.organizeByProviderFamily(models)

        XCTAssertEqual(groups.count, 1) // Only Anthropic
        let anthropic = groups[0]
        XCTAssertEqual(anthropic.families.count, 2) // Claude 4.6 and Claude 4.5
    }

    func test_organizeByProviderFamily_newestFamilyFirst() {
        let models = [
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", family: "Claude 4.5", sortOrder: 3),
            makeModel(id: "claude-opus-4-6", provider: "anthropic", family: "Claude 4.6", sortOrder: 0),
            makeModel(id: "claude-sonnet-4-20250514", provider: "anthropic", family: "Claude 4", sortOrder: 7),
        ]
        let groups = ModelFilteringService.organizeByProviderFamily(models)
        let families = groups[0].families

        XCTAssertEqual(families[0].id, "Claude 4.6")
        XCTAssertEqual(families[1].id, "Claude 4.5")
        XCTAssertEqual(families[2].id, "Claude 4")
    }

    func test_organizeByProviderFamily_latestFamilyMarked() {
        let models = [
            makeModel(id: "claude-opus-4-6", provider: "anthropic", family: "Claude 4.6", sortOrder: 0),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", family: "Claude 4.5", sortOrder: 3),
        ]
        let groups = ModelFilteringService.organizeByProviderFamily(models)
        let families = groups[0].families

        XCTAssertTrue(families[0].isLatest)  // Claude 4.6
        XCTAssertFalse(families[1].isLatest) // Claude 4.5
    }

    func test_organizeByProviderFamily_emptyProviderExcluded() {
        let models = [
            makeModel(id: "claude-opus-4-6", provider: "anthropic", family: "Claude 4.6"),
        ]
        let groups = ModelFilteringService.organizeByProviderFamily(models)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "anthropic")
    }

    func test_organizeByProviderFamily_handlesEmptyArray() {
        let groups = ModelFilteringService.organizeByProviderFamily([])
        XCTAssertTrue(groups.isEmpty)
    }

    func test_organizeByProviderFamily_fallsBackToIdParsing() {
        // No family field — should derive from ID
        let models = [
            makeModel(id: "claude-opus-4-6", provider: "anthropic"),
            makeModel(id: "gpt-5.3-codex", provider: "openai-codex"),
            makeModel(id: "gemini-3-pro-preview", provider: "google"),
        ]
        let groups = ModelFilteringService.organizeByProviderFamily(models)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].families[0].id, "Claude 4.6")
        XCTAssertEqual(groups[1].families[0].id, "GPT-5.3")
        XCTAssertEqual(groups[2].families[0].id, "Gemini 3")
    }

    func test_organizeByProviderFamily_modelsSortedBySortOrder() {
        let models = [
            makeModel(id: "claude-haiku-4-5-20250501", provider: "anthropic", family: "Claude 4.5", sortOrder: 4),
            makeModel(id: "claude-opus-4-5-20250501", provider: "anthropic", family: "Claude 4.5", sortOrder: 2),
            makeModel(id: "claude-sonnet-4-5-20250501", provider: "anthropic", family: "Claude 4.5", sortOrder: 3),
        ]
        let groups = ModelFilteringService.organizeByProviderFamily(models)
        let familyModels = groups[0].families[0].models

        // Sorted by sortOrder: 2, 3, 4
        XCTAssertEqual(familyModels[0].id, "claude-opus-4-5-20250501")
        XCTAssertEqual(familyModels[1].id, "claude-sonnet-4-5-20250501")
        XCTAssertEqual(familyModels[2].id, "claude-haiku-4-5-20250501")
    }

    // MARK: - Integration Tests

    func test_categorize_producesConsistentOrder() {
        let models = makeModels()

        let groups1 = ModelFilteringService.categorize(models)
        let groups2 = ModelFilteringService.categorize(models)

        XCTAssertEqual(groups1.count, groups2.count)
        for (g1, g2) in zip(groups1, groups2) {
            XCTAssertEqual(g1.tier, g2.tier)
            XCTAssertEqual(g1.models.map(\.id), g2.models.map(\.id))
        }
    }
}
