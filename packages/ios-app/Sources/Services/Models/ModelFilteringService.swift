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

    /// A family is deprecated when every model it contains is deprecated.
    /// Derived from per-model `isDeprecatedModel` — no separate server field.
    var isDeprecated: Bool {
        !models.isEmpty && models.allSatisfy { $0.isDeprecatedModel }
    }
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

        // Kimi models
        let kimi = models.filter { $0.isKimi && $0.isLatestGeneration }
            |> sortByTier
        if !kimi.isEmpty {
            groups.append(ModelGroup(tier: "Kimi", models: kimi))
        }

        // Legacy: everything marked legacy + unknown providers
        var legacyModels: [ModelInfo] = []
        legacyModels.append(contentsOf: (models.filter { $0.isAnthropic && !$0.isLatestGeneration }
            |> uniqueByFormattedName |> sortByTier))
        legacyModels.append(contentsOf: (models.filter { $0.isCodex && !$0.isLatestGeneration }
            |> sortByTier))
        legacyModels.append(contentsOf: (models.filter { $0.isGemini && !$0.isLatestGeneration }
            |> sortByTier))
        legacyModels.append(contentsOf: (models.filter { $0.isKimi && !$0.isLatestGeneration }
            |> sortByTier))
        legacyModels.append(contentsOf: models.filter {
            !$0.isAnthropic && !$0.isCodex && !$0.isGemini && !$0.isMiniMax && !$0.isKimi
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

        // Group models by provider
        var providerMap: [String: [ModelInfo]] = [:]
        for model in models {
            providerMap[model.provider, default: []].append(model)
        }

        // Sort providers by server-provided providerSortOrder
        let sortedProviders = providerMap.sorted { lhs, rhs in
            let lhsOrder = lhs.value.first?.providerSortOrder ?? 99
            let rhsOrder = rhs.value.first?.providerSortOrder ?? 99
            return lhsOrder < rhsOrder
        }

        var groups: [ProviderGroup] = []

        for (providerId, providerModels) in sortedProviders {
            // Use server-provided display name, fall back to provider ID
            let displayName = providerModels.first?.providerDisplayName ?? providerId
            let (color, icon) = providerVisuals(providerId)

            // Group by family (server always provides family)
            var familyMap: [String: [ModelInfo]] = [:]
            for model in providerModels {
                let fam = model.family ?? model.name
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
                id: providerId,
                displayName: displayName,
                families: familyGroups,
                color: color,
                icon: icon
            ))
        }

        return groups
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
        models.filter { !$0.isLegacy }
    }

    /// Filter to legacy versions only (server-driven via isLegacy flag)
    static func filterLegacy(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { $0.isLegacy }
    }

    // MARK: - Sorting

    /// Sort by server-provided sortOrder within each provider.
    /// Cross-provider: uses server-provided providerSortOrder.
    static func sortByTier(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { m1, m2 in
            if m1.provider != m2.provider {
                return (m1.providerSortOrder ?? 99) < (m2.providerSortOrder ?? 99)
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

    /// Provider visual theming (color + icon). These are display concerns, not business logic.
    private static func providerVisuals(_ providerId: String) -> (color: Color, icon: String) {
        switch providerId {
        case "anthropic": return (.tronCoral, "IconAnthropic")
        case "openai-codex": return (.tronSlate, "IconOpenAI")
        case "google": return (.tronCyan, "IconGoogle")
        case "minimax": return (.tronRose, "IconMiniMax")
        case "kimi": return (.tronIndigo, "IconKimi")
        case "ollama": return (.tronEmerald, "IconOllama")
        default: return (.secondary, "cpu")
        }
    }
}

// MARK: - Pipe Operator for Fluent Chaining

/// Pipe operator for fluent functional chaining
infix operator |>: AdditionPrecedence

private func |> <T, U>(_ value: T, _ transform: (T) -> U) -> U {
    transform(value)
}
