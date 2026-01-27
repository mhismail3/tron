import Foundation

// MARK: - Model Name Formatter

/// Unified model name formatting for Claude models.
/// Consolidates duplicate formatting logic from ChatView, Message, EventTypes, and RPCTypes.
enum ModelNameFormatter {

    /// Output format for model names
    enum Style {
        /// Short display: "Opus 4.5", "Sonnet 4"
        case short
        /// Compact lowercase: "opus-4.5", "sonnet-4"
        case compact
        /// Full display: "Claude Opus 4.5", "Claude Sonnet 4"
        case full
        /// Tier only: "Opus", "Sonnet", "Haiku"
        case tierOnly
    }

    /// Format a model ID string to the specified style
    /// - Parameters:
    ///   - modelId: The raw model ID (e.g., "claude-sonnet-4-20250514")
    ///   - style: The desired output format
    ///   - fallback: Optional fallback string if model can't be parsed
    /// - Returns: Formatted model name
    static func format(_ modelId: String, style: Style, fallback: String? = nil) -> String {
        let lowered = modelId.lowercased()

        // Check for OpenAI Codex models first
        if lowered.contains("codex") {
            return formatCodexModel(modelId, style: style)
        }

        // Check for Gemini models
        if lowered.contains("gemini") {
            return formatGeminiModel(modelId, style: style)
        }

        // Detect Claude tier
        let tier: Tier?
        if lowered.contains("opus") {
            tier = .opus
        } else if lowered.contains("sonnet") {
            tier = .sonnet
        } else if lowered.contains("haiku") {
            tier = .haiku
        } else {
            tier = nil
        }

        // Detect version (order matters: check more specific versions first)
        let version: Version?
        if lowered.contains("4-5") || lowered.contains("4.5") {
            version = .v4_5
        } else if lowered.contains("4-1") || lowered.contains("4.1") {
            version = .v4_1
        } else if lowered.contains("-4-") || lowered.contains("sonnet-4") ||
                  lowered.contains("opus-4") || lowered.contains("haiku-4") {
            version = .v4
        } else if lowered.contains("3-5") || lowered.contains("3.5") {
            version = .v3_5
        } else if lowered.contains("-3-") || lowered.contains("sonnet-3") ||
                  lowered.contains("opus-3") || lowered.contains("haiku-3") {
            version = .v3
        } else {
            version = nil
        }

        // If we couldn't detect tier, use fallback logic
        guard let tier = tier else {
            if let fallback = fallback {
                return fallback
            }
            // Fallback: first two components title-cased
            let parts = modelId.split(separator: "-")
            if parts.count >= 2 {
                return String(parts[0]).capitalized + " " + String(parts[1]).capitalized
            }
            return modelId
        }

        return formatOutput(tier: tier, version: version, style: style)
    }

    /// Format OpenAI Codex model IDs
    /// e.g., "gpt-5.2-codex" -> "GPT-5.2 Codex"
    ///       "gpt-5.1-codex-max" -> "GPT-5.1 Codex Max"
    ///       "gpt-5.1-codex-mini" -> "GPT-5.1 Codex Mini"
    private static func formatCodexModel(_ modelId: String, style: Style) -> String {
        let lowered = modelId.lowercased()

        // Extract version (5.2, 5.1, etc.)
        var version = ""
        if lowered.contains("5.2") {
            version = "5.2"
        } else if lowered.contains("5.1") {
            version = "5.1"
        } else if lowered.contains("5.0") || lowered.contains("-5-") {
            version = "5"
        }

        // Extract suffix (max, mini, etc.)
        var suffix = ""
        if lowered.contains("codex-max") {
            suffix = " Max"
        } else if lowered.contains("codex-mini") {
            suffix = " Mini"
        }

        switch style {
        case .tierOnly:
            return "Codex\(suffix)"
        case .short:
            if version.isEmpty {
                return "Codex\(suffix)"
            }
            return "GPT-\(version) Codex\(suffix)"
        case .compact:
            if version.isEmpty {
                return "codex\(suffix.lowercased().replacingOccurrences(of: " ", with: "-"))"
            }
            return "gpt-\(version)-codex\(suffix.lowercased().replacingOccurrences(of: " ", with: "-"))"
        case .full:
            if version.isEmpty {
                return "OpenAI Codex\(suffix)"
            }
            return "OpenAI GPT-\(version) Codex\(suffix)"
        }
    }

    /// Format Gemini model IDs
    /// e.g., "gemini-3-pro-preview" -> "Gemini 3 Pro"
    ///       "gemini-3-flash-preview" -> "Gemini 3 Flash"
    ///       "gemini-2.5-pro" -> "Gemini 2.5 Pro"
    private static func formatGeminiModel(_ modelId: String, style: Style) -> String {
        let lowered = modelId.lowercased()

        // Extract version
        var version = ""
        if lowered.contains("gemini-3") {
            version = "3"
        } else if lowered.contains("gemini-2.5") || lowered.contains("2-5") {
            version = "2.5"
        } else if lowered.contains("gemini-2") {
            version = "2"
        }

        // Extract tier
        var tier = ""
        if lowered.contains("flash-lite") {
            tier = "Flash Lite"
        } else if lowered.contains("flash") {
            tier = "Flash"
        } else if lowered.contains("pro") {
            tier = "Pro"
        }

        switch style {
        case .tierOnly:
            // Return version + tier for Gemini (e.g., "3 Flash", "3 Pro")
            if !version.isEmpty && !tier.isEmpty {
                return "\(version) \(tier)"
            } else if !tier.isEmpty {
                return tier
            }
            return "Gemini"
        case .short:
            // Return "Gemini 3 Flash", "Gemini 3 Pro"
            var parts = ["Gemini"]
            if !version.isEmpty { parts.append(version) }
            if !tier.isEmpty { parts.append(tier) }
            return parts.joined(separator: " ")
        case .compact:
            var parts = ["gemini"]
            if !version.isEmpty { parts.append(version) }
            if !tier.isEmpty { parts.append(tier.lowercased().replacingOccurrences(of: " ", with: "-")) }
            return parts.joined(separator: "-")
        case .full:
            // Same as short for Gemini (no "Google" prefix needed)
            var parts = ["Gemini"]
            if !version.isEmpty { parts.append(version) }
            if !tier.isEmpty { parts.append(tier) }
            return parts.joined(separator: " ")
        }
    }

    // MARK: - Private

    private enum Tier {
        case opus, sonnet, haiku

        var displayName: String {
            switch self {
            case .opus: return "Opus"
            case .sonnet: return "Sonnet"
            case .haiku: return "Haiku"
            }
        }

        var compactName: String {
            switch self {
            case .opus: return "opus"
            case .sonnet: return "sonnet"
            case .haiku: return "haiku"
            }
        }
    }

    private enum Version {
        case v3, v3_5, v4, v4_1, v4_5

        var displaySuffix: String {
            switch self {
            case .v3: return "3"
            case .v3_5: return "3.5"
            case .v4: return "4"
            case .v4_1: return "4.1"
            case .v4_5: return "4.5"
            }
        }

        var compactSuffix: String {
            switch self {
            case .v3: return "-3"
            case .v3_5: return "-3.5"
            case .v4: return "-4"
            case .v4_1: return "-4.1"
            case .v4_5: return "-4.5"
            }
        }
    }

    private static func formatOutput(tier: Tier, version: Version?, style: Style) -> String {
        switch style {
        case .tierOnly:
            return tier.displayName

        case .short:
            if let version = version {
                return "\(tier.displayName) \(version.displaySuffix)"
            }
            return tier.displayName

        case .compact:
            if let version = version {
                return "\(tier.compactName)\(version.compactSuffix)"
            }
            return tier.compactName

        case .full:
            if let version = version {
                return "Claude \(tier.displayName) \(version.displaySuffix)"
            }
            return "Claude \(tier.displayName)"
        }
    }
}

// MARK: - String Extension

extension String {
    /// Short model name: "Opus 4.5", "Sonnet 4"
    var shortModelName: String {
        ModelNameFormatter.format(self, style: .short)
    }

    /// Compact model name: "opus-4.5", "sonnet-4"
    var compactModelName: String {
        ModelNameFormatter.format(self, style: .compact)
    }

    /// Full model name: "Claude Opus 4.5", "Claude Sonnet 4"
    var fullModelName: String {
        ModelNameFormatter.format(self, style: .full)
    }

    /// Model tier only: "Opus", "Sonnet", "Haiku"
    var modelTier: String {
        ModelNameFormatter.format(self, style: .tierOnly)
    }
}

// MARK: - Quick Lookup Helper

/// Central mapping of model IDs to human-readable display names for known models
private let modelDisplayNames: [String: String] = [
    // Claude 4.5 family
    "claude-opus-4-5-20251101": "Opus 4.5",
    "claude-sonnet-4-5-20250929": "Sonnet 4.5",
    "claude-haiku-4-5-20251001": "Haiku 4.5",

    // Claude 4.1 family
    "claude-opus-4-1-20250805": "Opus 4.1",

    // Claude 4 family
    "claude-opus-4-20250514": "Opus 4",
    "claude-sonnet-4-20250514": "Sonnet 4",

    // Claude 3.7 family
    "claude-3-7-sonnet-20250219": "Sonnet 3.7",

    // Claude 3.5 family
    "claude-3-5-sonnet-20241022": "Sonnet 3.5",
    "claude-3-5-sonnet-20240620": "Sonnet 3.5",
    "claude-3-5-haiku-20241022": "Haiku 3.5",

    // Claude 3 family
    "claude-3-opus-20240229": "Opus 3",
    "claude-3-sonnet-20240229": "Sonnet 3",
    "claude-3-haiku-20240307": "Haiku 3",
]

/// Formats a model ID into a friendly display name using the central mapping.
/// Falls back to shortModelName for models not in the lookup table.
func formatModelDisplayName(_ modelId: String) -> String {
    // Direct lookup first
    if let displayName = modelDisplayNames[modelId] {
        return displayName
    }

    // Use ModelNameFormatter for all other models (Gemini, Codex, etc.)
    return modelId.shortModelName
}
