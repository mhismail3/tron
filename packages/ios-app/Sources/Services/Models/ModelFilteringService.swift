import Foundation

/// Service for filtering, categorizing, and sorting model lists.
/// Extracts business logic from Views to provide consistent model organization.
enum ModelFilteringService {

    // MARK: - Categorization

    /// Categorize models into logical groups for UI display.
    /// Groups: Anthropic (Latest), OpenAI Codex (Latest), Gemini 3, Legacy
    static func categorize(_ models: [ModelInfo]) -> [ModelGroup] {
        guard !models.isEmpty else { return [] }

        var groups: [ModelGroup] = []

        // Anthropic 4.5 models (latest)
        let latestAnthropic = models.filter { $0.isAnthropic && $0.is45Model }
            |> uniqueByFormattedName
            |> sortByTier
        if !latestAnthropic.isEmpty {
            groups.append(ModelGroup(tier: "Anthropic (Latest)", models: latestAnthropic))
        }

        // OpenAI Codex 5.2 (latest)
        let latestCodex = models.filter { $0.isCodex && $0.id.lowercased().contains("5.2") }
        if !latestCodex.isEmpty {
            groups.append(ModelGroup(tier: "OpenAI Codex (Latest)", models: latestCodex))
        }

        // Gemini 3 models (latest)
        let gemini3 = models.filter { $0.isGemini3 }
            |> sortByGeminiTier
        if !gemini3.isEmpty {
            groups.append(ModelGroup(tier: "Gemini 3", models: gemini3))
        }

        // Legacy: everything else
        var legacyModels: [ModelInfo] = []

        // Legacy Anthropic (non-4.5)
        let legacyAnthropic = models.filter { $0.isAnthropic && !$0.is45Model }
            |> uniqueByFormattedName
            |> sortByTier
        legacyModels.append(contentsOf: legacyAnthropic)

        // Legacy Codex (5.1, 5.0, etc.)
        let legacyCodex = models.filter { $0.isCodex && !$0.id.lowercased().contains("5.2") }
            |> sortByCodexVersion
        legacyModels.append(contentsOf: legacyCodex)

        // Legacy Gemini (2.5, 2.0)
        let legacyGemini = models.filter { $0.isGemini && !$0.isGemini3 }
            |> sortByGeminiTier
        legacyModels.append(contentsOf: legacyGemini)

        // Unknown providers (not Anthropic, Codex, or Gemini)
        let unknown = models.filter {
            !$0.isAnthropic && !$0.isCodex && !$0.isGemini
        }
        legacyModels.append(contentsOf: unknown)

        if !legacyModels.isEmpty {
            groups.append(ModelGroup(tier: "Legacy", models: legacyModels))
        }

        return groups
    }

    // MARK: - Filtering

    /// Filter to latest versions only (4.5, 5.2, Gemini 3)
    static func filterLatest(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { model in
            (model.isAnthropic && model.is45Model) ||
            (model.isCodex && model.id.lowercased().contains("5.2")) ||
            model.isGemini3
        }
    }

    /// Filter to legacy versions only
    static func filterLegacy(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { model in
            if model.isAnthropic { return !model.is45Model }
            if model.isCodex { return !model.id.lowercased().contains("5.2") }
            if model.isGemini { return !model.isGemini3 }
            return true
        }
    }

    // MARK: - Sorting

    /// Sort by tier/version priority.
    /// Anthropic: Opus > Sonnet > Haiku, newer versions first within tier.
    /// Codex: 5.2 > 5.1 > 5.0
    /// Gemini: Pro > Flash > Flash Lite
    static func sortByTier(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { m1, m2 in
            // Different providers: sort by provider
            if m1.provider != m2.provider {
                return providerPriority(m1) < providerPriority(m2)
            }

            // Same provider: use provider-specific sorting
            if m1.isAnthropic {
                return compareAnthropic(m1, m2)
            } else if m1.isCodex {
                return codexVersionPriority(m1) > codexVersionPriority(m2)
            } else if m1.isGemini {
                return geminiTierPriority(m1) < geminiTierPriority(m2)
            }

            // Fallback: alphabetical
            return m1.id < m2.id
        }
    }

    /// Sort Codex models by version (5.2 > 5.1 > 5.0)
    static func sortByCodexVersion(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { codexVersionPriority($0) > codexVersionPriority($1) }
    }

    /// Sort Gemini models by tier (Pro > Flash > Flash Lite)
    static func sortByGeminiTier(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { geminiTierPriority($0) < geminiTierPriority($1) }
    }

    // MARK: - Deduplication

    /// Deduplicate by formatted display name (keeps first occurrence)
    static func uniqueByFormattedName(_ models: [ModelInfo]) -> [ModelInfo] {
        var seen = Set<String>()
        return models.filter { model in
            let name = model.formattedModelName
            if seen.contains(name) { return false }
            seen.insert(name)
            return true
        }
    }

    // MARK: - Private Helpers

    private static func providerPriority(_ model: ModelInfo) -> Int {
        if model.isAnthropic { return 0 }
        if model.isCodex { return 1 }
        if model.isGemini { return 2 }
        return 99
    }

    private static func compareAnthropic(_ m1: ModelInfo, _ m2: ModelInfo) -> Bool {
        let tier1 = anthropicTierPriority(m1)
        let tier2 = anthropicTierPriority(m2)
        if tier1 != tier2 {
            return tier1 < tier2  // Opus (0) < Sonnet (1) < Haiku (2)
        }
        // Same tier: newer version first
        return anthropicVersionPriority(m1) > anthropicVersionPriority(m2)
    }

    private static func anthropicTierPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("opus") { return 0 }
        if id.contains("sonnet") { return 1 }
        if id.contains("haiku") { return 2 }
        return 3
    }

    private static func anthropicVersionPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("4-5") || id.contains("4.5") { return 45 }
        if id.contains("4-1") || id.contains("4.1") { return 41 }
        if id.contains("-4-") || id.contains("opus-4") || id.contains("sonnet-4") || id.contains("haiku-4") { return 40 }
        if id.contains("3-5") || id.contains("3.5") { return 35 }
        if id.contains("-3-") { return 30 }
        return 0
    }

    private static func codexVersionPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("5.2") { return 52 }
        if id.contains("5.1") { return 51 }
        if id.contains("5.0") || id.contains("-5-") { return 50 }
        return 0
    }

    private static func geminiTierPriority(_ model: ModelInfo) -> Int {
        switch model.geminiTier {
        case "pro": return 0
        case "flash": return 1
        case "flash-lite": return 2
        default: return 3
        }
    }
}

// MARK: - Pipe Operator for Fluent Chaining

/// Pipe operator for fluent functional chaining
infix operator |>: AdditionPrecedence

private func |> <T, U>(_ value: T, _ transform: (T) -> U) -> U {
    transform(value)
}
