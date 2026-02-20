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
    /// Uses server-provided `isLegacy` flag for categorization.
    static func categorize(_ models: [ModelInfo]) -> [ModelGroup] {
        guard !models.isEmpty else { return [] }

        var groups: [ModelGroup] = []

        // Latest models by provider
        let latestAnthropic = models.filter { $0.isAnthropic && $0.isLatestGeneration }
            |> uniqueByFormattedName
            |> sortByTier
        if !latestAnthropic.isEmpty {
            groups.append(ModelGroup(tier: "Anthropic (Latest)", models: latestAnthropic))
        }

        let latestCodex = models.filter { $0.isCodex && $0.isLatestGeneration }
            |> sortByTier
        if !latestCodex.isEmpty {
            groups.append(ModelGroup(tier: "OpenAI Codex (Latest)", models: latestCodex))
        }

        let latestGemini = models.filter { $0.isGemini && $0.isLatestGeneration }
            |> sortByTier
        if !latestGemini.isEmpty {
            let label = latestGemini.first.flatMap(\.family) ?? "Gemini (Latest)"
            groups.append(ModelGroup(tier: label, models: latestGemini))
        }

        // MiniMax models
        let minimax = models.filter { $0.isMiniMax }
            |> sortByTier
        if !minimax.isEmpty {
            groups.append(ModelGroup(tier: "MiniMax", models: minimax))
        }

        // Legacy: everything marked legacy + unknown providers
        var legacyModels: [ModelInfo] = []
        legacyModels.append(contentsOf: (models.filter { $0.isAnthropic && !$0.isLatestGeneration }
            |> uniqueByFormattedName |> sortByTier))
        legacyModels.append(contentsOf: (models.filter { $0.isCodex && !$0.isLatestGeneration }
            |> sortByTier))
        legacyModels.append(contentsOf: (models.filter { $0.isGemini && !$0.isLatestGeneration }
            |> sortByTier))
        legacyModels.append(contentsOf: models.filter {
            !$0.isAnthropic && !$0.isCodex && !$0.isGemini && !$0.isMiniMax
        })

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
            ProviderDef(id: "anthropic", displayName: "Anthropic", color: .tronAmber, icon: "IconAnthropic",
                        filter: { $0.isAnthropic }),
            ProviderDef(id: "openai-codex", displayName: "OpenAI", color: .tronSlate, icon: "IconOpenAI",
                        filter: { $0.isCodex }),
            ProviderDef(id: "google", displayName: "Google", color: .tronCyan, icon: "IconGoogle",
                        filter: { $0.isGemini }),
            ProviderDef(id: "minimax", displayName: "MiniMax", color: .tronIndigo, icon: "IconMiniMax",
                        filter: { $0.isMiniMax }),
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
                let sorted = familyModels.sorted { ($0.sortOrder ?? 999) < ($1.sortOrder ?? 999) }
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
            if id.contains("3-7") || id.contains("3.7") { return "Claude 3.7" }
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
        // MiniMax
        if id.contains("minimax") {
            return "MiniMax M2"
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

    /// Filter to latest versions only (server-driven via isLegacy flag)
    static func filterLatest(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { !($0.isLegacy ?? false) }
    }

    /// Filter to legacy versions only (server-driven via isLegacy flag)
    static func filterLegacy(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { $0.isLegacy ?? false }
    }

    // MARK: - Sorting

    /// Sort by server-provided sortOrder within each provider.
    /// Cross-provider: uses providerPriority.
    static func sortByTier(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { m1, m2 in
            if m1.provider != m2.provider {
                return providerPriority(m1) < providerPriority(m2)
            }
            return (m1.sortOrder ?? 999) < (m2.sortOrder ?? 999)
        }
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
        if model.isMiniMax { return 3 }
        return 99
    }
}

// MARK: - Pipe Operator for Fluent Chaining

/// Pipe operator for fluent functional chaining
infix operator |>: AdditionPrecedence

private func |> <T, U>(_ value: T, _ transform: (T) -> U) -> U {
    transform(value)
}
