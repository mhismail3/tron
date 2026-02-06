import Foundation
import SwiftUI

// MARK: - Provider/Family Hierarchy Types

struct ProviderGroup: Identifiable {
    let id: String           // "anthropic", "openai-codex", "google"
    let displayName: String  // "Anthropic", "OpenAI", "Google"
    let families: [FamilyGroup]
    let color: Color         // .tronEmerald, .tronPurple, .tronAmber
    let icon: String         // SF Symbol name
}

struct FamilyGroup: Identifiable {
    let id: String           // "Claude 4.6", "GPT-5.3", "Gemini 3"
    let models: [ModelInfo]
    let isLatest: Bool       // expanded by default
}

// MARK: - Model Group (flat tier-based grouping)

struct ModelGroup {
    let tier: String
    let models: [ModelInfo]
}

// MARK: - Array Extensions for Model Filtering

extension Array where Element == ModelInfo {
    func uniqueByFormattedName() -> [ModelInfo] {
        ModelFilteringService.uniqueByFormattedName(self)
    }

    func sortedByTier() -> [ModelInfo] {
        ModelFilteringService.sortByTier(self)
    }
}

/// Service for filtering, categorizing, and sorting model lists.
/// Extracts business logic from Views to provide consistent model organization.
enum ModelFilteringService {

    // MARK: - Categorization

    /// Categorize models into logical groups for UI display.
    /// Groups: Anthropic (Latest), OpenAI Codex (Latest), Gemini 3, Legacy
    static func categorize(_ models: [ModelInfo]) -> [ModelGroup] {
        guard !models.isEmpty else { return [] }

        var groups: [ModelGroup] = []

        // Anthropic latest (4.5+/4.6+)
        let latestAnthropic = models.filter { $0.isAnthropic && $0.isLatestGeneration }
            |> uniqueByFormattedName
            |> sortByTier
        if !latestAnthropic.isEmpty {
            groups.append(ModelGroup(tier: "Anthropic (Latest)", models: latestAnthropic))
        }

        // OpenAI Codex 5.3 (latest)
        let latestCodex = models.filter { $0.isCodex && $0.id.lowercased().contains("5.3") }
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
        let legacyAnthropic = models.filter { $0.isAnthropic && !$0.isLatestGeneration }
            |> uniqueByFormattedName
            |> sortByTier
        legacyModels.append(contentsOf: legacyAnthropic)

        // Legacy Codex (5.2, 5.1, 5.0, etc.)
        let legacyCodex = models.filter { $0.isCodex && !$0.id.lowercased().contains("5.3") }
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

    // MARK: - Provider/Family Hierarchy

    /// Organize models into Provider > Family > Model hierarchy for the rich picker sheet.
    static func organizeByProviderFamily(_ models: [ModelInfo]) -> [ProviderGroup] {
        guard !models.isEmpty else { return [] }

        struct ProviderDef {
            let id: String
            let displayName: String
            let color: Color
            let icon: String
            let filter: (ModelInfo) -> Bool
        }

        let providers: [ProviderDef] = [
            ProviderDef(id: "anthropic", displayName: "Anthropic", color: .tronEmerald, icon: "sparkles",
                        filter: { $0.isAnthropic }),
            ProviderDef(id: "openai-codex", displayName: "OpenAI", color: .tronPurple, icon: "bolt",
                        filter: { $0.isCodex }),
            ProviderDef(id: "google", displayName: "Google", color: .tronAmber, icon: "atom",
                        filter: { $0.isGemini }),
        ]

        var groups: [ProviderGroup] = []

        for provider in providers {
            let providerModels = models.filter(provider.filter)
            guard !providerModels.isEmpty else { continue }

            // Group by family
            var familyMap: [String: [ModelInfo]] = [:]
            for model in providerModels {
                let fam = model.family ?? deriveFamilyFromId(model)
                familyMap[fam, default: []].append(model)
            }

            // Sort families by version descending (newest first)
            let sortedFamilies = familyMap.sorted { extractVersion($0.key) > extractVersion($1.key) }

            var familyGroups: [FamilyGroup] = []
            for (index, (familyName, familyModels)) in sortedFamilies.enumerated() {
                let sorted = sortByTier(familyModels)
                familyGroups.append(FamilyGroup(
                    id: familyName,
                    models: sorted,
                    isLatest: index == 0
                ))
            }

            groups.append(ProviderGroup(
                id: provider.id,
                displayName: provider.displayName,
                families: familyGroups,
                color: provider.color,
                icon: provider.icon
            ))
        }

        return groups
    }

    /// Derive a family name from model ID when the server doesn't provide one
    private static func deriveFamilyFromId(_ model: ModelInfo) -> String {
        let id = model.id.lowercased()
        // Anthropic
        if id.contains("claude") {
            if id.contains("4-6") || id.contains("4.6") { return "Claude 4.6" }
            if id.contains("4-5") || id.contains("4.5") { return "Claude 4.5" }
            if id.contains("4-1") || id.contains("4.1") { return "Claude 4.1" }
            if id.contains("opus-4") || id.contains("sonnet-4") || id.contains("haiku-4") { return "Claude 4" }
            if id.contains("3-5") || id.contains("3.5") { return "Claude 3.5" }
            return "Claude"
        }
        // OpenAI Codex
        if id.contains("codex") || id.contains("gpt") {
            if id.contains("5.3") { return "GPT-5.3" }
            if id.contains("5.2") { return "GPT-5.2" }
            if id.contains("5.1") { return "GPT-5.1" }
            if id.contains("5.0") || id.contains("-5-") { return "GPT-5.0" }
            return "GPT"
        }
        // Gemini
        if id.contains("gemini") {
            if id.contains("gemini-3") { return "Gemini 3" }
            if id.contains("gemini-2.5") || id.contains("2-5") { return "Gemini 2.5" }
            if id.contains("gemini-2") { return "Gemini 2" }
            return "Gemini"
        }
        return model.name
    }

    /// Extract a numeric version from a family name for sorting (e.g., "Claude 4.6" → 4.6)
    private static func extractVersion(_ familyName: String) -> Double {
        // Match patterns like "4.6", "5.3", "2.5", "3", "4.1"
        let pattern = #"(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: familyName, range: NSRange(familyName.startIndex..., in: familyName)),
              let range = Range(match.range(at: 1), in: familyName) else {
            return 0
        }
        return Double(familyName[range]) ?? 0
    }

    // MARK: - Filtering

    /// Filter to latest versions only (4.5, 5.3, Gemini 3)
    static func filterLatest(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { model in
            (model.isAnthropic && model.isLatestGeneration) ||
            (model.isCodex && model.id.lowercased().contains("5.3")) ||
            model.isGemini3
        }
    }

    /// Filter to legacy versions only
    static func filterLegacy(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { model in
            if model.isAnthropic { return !model.isLatestGeneration }
            if model.isCodex { return !model.id.lowercased().contains("5.3") }
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
        if id.contains("4-6") || id.contains("4.6") { return 46 }
        if id.contains("4-5") || id.contains("4.5") { return 45 }
        if id.contains("4-1") || id.contains("4.1") { return 41 }
        if id.contains("-4-") || id.contains("opus-4") || id.contains("sonnet-4") || id.contains("haiku-4") { return 40 }
        if id.contains("3-5") || id.contains("3.5") { return 35 }
        if id.contains("-3-") { return 30 }
        return 0
    }

    private static func codexVersionPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("5.3") { return 53 }
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
