import Foundation

// MARK: - Model Methods

struct ModelSwitchParams: Encodable {
    let sessionId: String
    let model: String
}

struct ModelSwitchResult: Decodable {
    let previousModel: String
    let newModel: String
}

struct ModelInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let contextWindow: Int
    let maxOutputTokens: Int?
    let supportsThinking: Bool?
    let supportsImages: Bool?
    let tier: String?
    let isLegacy: Bool?
    /// For models with reasoning capability (e.g., OpenAI Codex)
    let supportsReasoning: Bool?
    /// Available reasoning effort levels (low, medium, high, xhigh)
    let reasoningLevels: [String]?
    /// Default reasoning level
    let defaultReasoningLevel: String?
    /// For Gemini models: default thinking level
    let thinkingLevel: String?
    /// For Gemini models: available thinking levels
    let supportedThinkingLevels: [String]?

    /// Properly formatted display name (e.g., "Claude Opus 4.5", "Claude Sonnet 4")
    var displayName: String {
        // For OpenAI models, use the name directly
        if provider == "openai-codex" || provider == "openai" {
            return name
        }
        return id.fullModelName
    }

    /// Short tier name: "Opus", "Sonnet", "Haiku"
    var shortName: String {
        // For OpenAI models, use the name directly
        if provider == "openai-codex" || provider == "openai" {
            return name
        }
        return ModelNameFormatter.format(id, style: .tierOnly, fallback: name)
    }

    /// Formats model name properly: "Claude Opus 4.5", "GPT-5.2 Codex", "Gemini 3 Pro", etc.
    /// Uses full format for Claude models, short format for Codex (avoids redundant "OpenAI" prefix)
    var formattedModelName: String {
        let lowerId = id.lowercased()
        if lowerId.contains("codex") {
            // Codex: "GPT-5.2 Codex" (short format - no "OpenAI" prefix)
            return id.shortModelName
        }
        if lowerId.contains("gemini") {
            // Gemini: Use the server-provided name or format nicely
            // e.g., "gemini-3-pro-preview" → "Gemini 3 Pro"
            return formatGeminiName()
        }
        // Claude: "Claude Opus 4.5" (full format with "Claude" prefix)
        return id.fullModelName
    }

    /// Format Gemini model name nicely
    private func formatGeminiName() -> String {
        // If server provides a good name, use it
        if !name.lowercased().contains("gemini") {
            // Server name doesn't mention Gemini, construct it
        } else if name != id {
            return name
        }

        // Parse from ID: "gemini-3-pro-preview" → "Gemini 3 Pro"
        let lowerId = id.lowercased()
        var parts: [String] = ["Gemini"]

        // Version
        if lowerId.contains("gemini-3") {
            parts.append("3")
        } else if lowerId.contains("gemini-2.5") || lowerId.contains("2-5") {
            parts.append("2.5")
        } else if lowerId.contains("gemini-2") {
            parts.append("2")
        }

        // Tier
        if lowerId.contains("flash-lite") {
            parts.append("Flash Lite")
        } else if lowerId.contains("flash") {
            parts.append("Flash")
        } else if lowerId.contains("pro") {
            parts.append("Pro")
        }

        return parts.joined(separator: " ")
    }

    /// Whether this is a latest generation model (Claude 4.5+/4.6+, GPT-5.x Codex, or Gemini 3)
    var isLatestGeneration: Bool {
        let lowerId = id.lowercased()
        // Claude 4.5 and 4.6 families
        if lowerId.hasPrefix("claude") && (lowerId.contains("4-5") || lowerId.contains("4.5") ||
           lowerId.contains("4-6") || lowerId.contains("4.6")) {
            return true
        }
        // GPT-5.x Codex models are also "latest"
        if lowerId.contains("codex") && (lowerId.contains("5.") || lowerId.contains("-5-")) {
            return true
        }
        // Gemini 3 models are also "latest"
        if lowerId.contains("gemini-3") {
            return true
        }
        return false
    }

    /// Whether this is an Anthropic model
    var isAnthropic: Bool {
        provider == "anthropic"
    }

    /// Whether this is an OpenAI Codex model
    var isCodex: Bool {
        provider == "openai-codex"
    }

    /// Whether this is a Google Gemini model
    var isGemini: Bool {
        provider == "google" || id.lowercased().contains("gemini")
    }

    /// Whether this is a Gemini 3 model (latest Google models)
    var isGemini3: Bool {
        let lowerId = id.lowercased()
        return isGemini && lowerId.contains("gemini-3")
    }

    /// Whether this is a preview model
    var isPreview: Bool {
        id.lowercased().contains("preview")
    }

    /// Gemini tier (pro, flash, flash-lite)
    var geminiTier: String? {
        guard isGemini else { return nil }
        let lowerId = id.lowercased()
        if lowerId.contains("flash-lite") { return "flash-lite" }
        if lowerId.contains("flash") { return "flash" }
        if lowerId.contains("pro") { return "pro" }
        return nil
    }
}

struct ModelListResult: Decodable {
    let models: [ModelInfo]
}
