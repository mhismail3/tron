import Foundation
import os

// MARK: - Model Name Formatter

/// Unified model name formatting for Claude models.
/// Uses server-provided metadata when available, falls back to ID heuristic parsing.
enum ModelNameFormatter {

    /// Lock-protected server model cache. Written by ModelClient, read from any context.
    private static let _serverModels = OSAllocatedUnfairLock<[String: ModelInfo]>(initialState: [:])

    /// Thread-safe snapshot of all server models. Copies the entire dictionary.
    /// Prefer `lookupModel(_:)` for single-key lookups to avoid full copy.
    static var serverModels: [String: ModelInfo] {
        _serverModels.withLock { $0 }
    }

    /// Thread-safe single-key lookup — avoids copying the full dictionary.
    private static func lookupModel(_ id: String) -> ModelInfo? {
        _serverModels.withLock { $0[id] }
    }

    static func updateFromServer(_ models: [ModelInfo]) {
        _serverModels.withLock { $0 = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) }) }
    }

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
    static func format(_ rawModelId: String, style: Style, fallback: String? = nil) -> String {
        // Strip explicit provider prefix (e.g. "openai/gpt-5.4" → "gpt-5.4")
        let modelId = rawModelId.contains("/")
            ? String(rawModelId.split(separator: "/", maxSplits: 1).last ?? Substring(rawModelId))
            : rawModelId

        // Use server metadata when available
        if let info = lookupModel(modelId) {
            switch style {
            case .short:
                return info.name
            case .full:
                return info.isAnthropic ? "Claude \(info.name)" : info.name
            case .compact:
                return info.name.lowercased().replacingOccurrences(of: " ", with: "-")
            case .tierOnly:
                return info.isAnthropic ? info.tier.capitalized : info.name
            }
        }

        // Fallback: heuristic ID parsing for models not in cache
        let lowered = modelId.lowercased()

        // Check for OpenAI GPT models
        if lowered.hasPrefix("gpt-") {
            return formatGptModel(modelId, style: style)
        }

        // Check for Gemini models
        if lowered.contains("gemini") {
            return formatGeminiModel(modelId, style: style)
        }

        // Check for MiniMax models
        if lowered.hasPrefix("minimax-") {
            return formatMiniMaxModel(modelId, style: style)
        }

        // Check for Kimi / Moonshot models
        if lowered.hasPrefix("kimi-") || lowered.hasPrefix("moonshot-") {
            return formatKimiModel(modelId, style: style)
        }

        // Check for Ollama models (gemma4:variant)
        if lowered.hasPrefix("gemma") {
            return formatOllamaModel(modelId, style: style)
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
        if lowered.contains("4-6") || lowered.contains("4.6") {
            version = .v4_6
        } else if lowered.contains("4-5") || lowered.contains("4.5") {
            version = .v4_5
        } else if lowered.contains("4-1") || lowered.contains("4.1") {
            version = .v4_1
        } else if lowered.contains("-4-") || lowered.contains("sonnet-4") ||
                  lowered.contains("opus-4") || lowered.contains("haiku-4") {
            version = .v4
        } else if lowered.contains("3-7") || lowered.contains("3.7") {
            version = .v3_7
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

    /// Format OpenAI GPT model IDs
    /// e.g., "gpt-5.4" -> "GPT-5.4", "gpt-5.4-pro" -> "GPT-5.4 Pro"
    ///       "gpt-5.3-codex-spark" -> "GPT-5.3 Spark"
    private static func formatGptModel(_ modelId: String, style: Style) -> String {
        let lowered = modelId.lowercased()

        // Extract version (5.4, 5.3, 5.2, 5.1, etc.)
        var version = ""
        if lowered.contains("5.4") {
            version = "5.4"
        } else if lowered.contains("5.3") {
            version = "5.3"
        } else if lowered.contains("5.2") {
            version = "5.2"
        } else if lowered.contains("5.1") {
            version = "5.1"
        } else if lowered.contains("5.0") || lowered.contains("-5-") {
            version = "5"
        }

        // Extract suffix (pro, mini, max, spark, etc.)
        var suffix = ""
        if lowered.hasSuffix("-pro") {
            suffix = " Pro"
        } else if lowered.contains("-mini") {
            suffix = " Mini"
        } else if lowered.contains("-max") {
            suffix = " Max"
        } else if lowered.contains("-spark") {
            suffix = " Spark"
        }

        switch style {
        case .tierOnly:
            return "GPT\(suffix)"
        case .short:
            if version.isEmpty {
                return "GPT\(suffix)"
            }
            return "GPT-\(version)\(suffix)"
        case .compact:
            return "gpt-\(version)\(suffix.lowercased().replacingOccurrences(of: " ", with: "-"))"
        case .full:
            if version.isEmpty {
                return "GPT\(suffix)"
            }
            return "GPT-\(version)\(suffix)"
        }
    }

    /// Format Gemini model IDs
    /// e.g., "gemini-3-pro-preview" -> "Gemini 3 Pro"
    ///       "gemini-3-flash-preview" -> "Gemini 3 Flash"
    ///       "gemini-2.5-pro" -> "Gemini 2.5 Pro"
    private static func formatGeminiModel(_ modelId: String, style: Style) -> String {
        let lowered = modelId.lowercased()

        // Extract version (check more specific first)
        var version = ""
        if lowered.contains("gemini-3.1") {
            version = "3.1"
        } else if lowered.contains("gemini-3") {
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

    /// Format MiniMax model IDs
    /// e.g., "MiniMax-M2.7" -> "MiniMax M2.7", "MiniMax-M2.7-highspeed" -> "MiniMax M2.7 HS"
    private static func formatMiniMaxModel(_ modelId: String, style: Style) -> String {
        let lowered = modelId.lowercased()

        // Extract version
        var version = ""
        if lowered.contains("m2.7") { version = "M2.7" }
        else if lowered.contains("m2.5") { version = "M2.5" }
        else if lowered.contains("m2.1") { version = "M2.1" }
        else if lowered.contains("m2") { version = "M2" }

        let hs = lowered.contains("highspeed") ? " HS" : ""

        switch style {
        case .tierOnly:
            return "\(version)\(hs)"
        case .short, .compact:
            return "MiniMax \(version)\(hs)"
        case .full:
            return "MiniMax \(version)\(hs)"
        }
    }

    /// Format Kimi / Moonshot model IDs
    /// e.g., "kimi-k2.5" -> "Kimi K2.5", "moonshot-v1-128k" -> "Moonshot V1 128K"
    private static func formatKimiModel(_ modelId: String, style: Style) -> String {
        let lowered = modelId.lowercased()

        if lowered.hasPrefix("moonshot-") {
            // Legacy moonshot models
            var ctx = ""
            if lowered.contains("128k") { ctx = "128K" }
            else if lowered.contains("32k") { ctx = "32K" }
            else if lowered.contains("8k") { ctx = "8K" }
            let name = ctx.isEmpty ? "Moonshot V1" : "Moonshot V1 \(ctx)"
            return style == .compact ? name.lowercased().replacingOccurrences(of: " ", with: "-") : name
        }

        // Kimi K2 variants
        var suffix = ""
        if lowered.contains("k2.5") {
            suffix = "K2.5"
        } else if lowered.contains("k2-thinking-turbo") {
            suffix = "K2 Think Turbo"
        } else if lowered.contains("k2-thinking") {
            suffix = "K2 Think"
        } else if lowered.contains("k2-turbo") {
            suffix = "K2 Turbo"
        } else if lowered.contains("k2-0905") {
            suffix = "K2 0905"
        } else if lowered.contains("k2-0711") {
            suffix = "K2 0711"
        } else {
            suffix = "K2"
        }

        switch style {
        case .tierOnly:
            return suffix
        case .compact:
            return "kimi-\(suffix.lowercased().replacingOccurrences(of: " ", with: "-"))"
        case .short, .full:
            return "Kimi \(suffix)"
        }
    }

    /// Format Ollama local model IDs
    /// e.g., "gemma4:e4b" -> "Gemma 4 E4B", "gemma4:26b" -> "Gemma 4 26B"
    private static func formatOllamaModel(_ modelId: String, style: Style) -> String {
        let parts = modelId.split(separator: ":")
        let base = String(parts.first ?? Substring(modelId))
        let variant = parts.count > 1 ? String(parts[1]).uppercased() : ""

        // Extract name and version from e.g. "gemma4"
        var name = "Gemma"
        if let range = base.range(of: #"[0-9]+"#, options: .regularExpression) {
            name = "\(base[base.startIndex..<range.lowerBound].capitalized) \(base[range])"
        }

        let display = variant.isEmpty ? name : "\(name) \(variant)"
        return style == .compact ? display.lowercased().replacingOccurrences(of: " ", with: "-") : display
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
        case v3, v3_5, v3_7, v4, v4_1, v4_5, v4_6

        var displaySuffix: String {
            switch self {
            case .v3: return "3"
            case .v3_5: return "3.5"
            case .v3_7: return "3.7"
            case .v4: return "4"
            case .v4_1: return "4.1"
            case .v4_5: return "4.5"
            case .v4_6: return "4.6"
            }
        }

        var compactSuffix: String {
            switch self {
            case .v3: return "-3"
            case .v3_5: return "-3.5"
            case .v3_7: return "-3.7"
            case .v4: return "-4"
            case .v4_1: return "-4.1"
            case .v4_5: return "-4.5"
            case .v4_6: return "-4.6"
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

/// Formats a model ID into a friendly display name.
/// Uses server cache when available, falls back to heuristic parsing.
func formatModelDisplayName(_ modelId: String) -> String {
    ModelNameFormatter.format(modelId, style: .short)
}
