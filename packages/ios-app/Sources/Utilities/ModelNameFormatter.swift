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

        // Detect version
        let version: Version?
        if lowered.contains("4-5") || lowered.contains("4.5") {
            version = .v4_5
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
        case v3, v3_5, v4, v4_5

        var displaySuffix: String {
            switch self {
            case .v3: return "3"
            case .v3_5: return "3.5"
            case .v4: return "4"
            case .v4_5: return "4.5"
            }
        }

        var compactSuffix: String {
            switch self {
            case .v3: return "-3"
            case .v3_5: return "-3.5"
            case .v4: return "-4"
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
