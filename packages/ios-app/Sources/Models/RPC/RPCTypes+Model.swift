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

    // MARK: - Rich Metadata (from model.list v2)

    /// Model family (e.g., "Claude 4.6", "GPT-5.3", "Gemini 3")
    let family: String?
    /// Maximum output tokens
    let maxOutput: Int?
    /// Brief description of the model
    let modelDescription: String?
    /// Input cost per million tokens (USD)
    let inputCostPerMillion: Double?
    /// Output cost per million tokens (USD)
    let outputCostPerMillion: Double?
    /// Whether this is the recommended model in its tier
    let recommended: Bool?
    /// Release date (YYYY-MM-DD)
    let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, contextWindow, maxOutputTokens
        case supportsThinking, supportsImages, tier, isLegacy
        case supportsReasoning, reasoningLevels, defaultReasoningLevel
        case thinkingLevel, supportedThinkingLevels
        case family, maxOutput, recommended, releaseDate
        case inputCostPerMillion, outputCostPerMillion
        case modelDescription = "description"
    }

    /// Manual init preserving backward compatibility — new metadata fields default to nil
    init(
        id: String,
        name: String,
        provider: String,
        contextWindow: Int,
        maxOutputTokens: Int? = nil,
        supportsThinking: Bool? = nil,
        supportsImages: Bool? = nil,
        tier: String? = nil,
        isLegacy: Bool? = nil,
        supportsReasoning: Bool? = nil,
        reasoningLevels: [String]? = nil,
        defaultReasoningLevel: String? = nil,
        thinkingLevel: String? = nil,
        supportedThinkingLevels: [String]? = nil,
        family: String? = nil,
        maxOutput: Int? = nil,
        modelDescription: String? = nil,
        inputCostPerMillion: Double? = nil,
        outputCostPerMillion: Double? = nil,
        recommended: Bool? = nil,
        releaseDate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsThinking = supportsThinking
        self.supportsImages = supportsImages
        self.tier = tier
        self.isLegacy = isLegacy
        self.supportsReasoning = supportsReasoning
        self.reasoningLevels = reasoningLevels
        self.defaultReasoningLevel = defaultReasoningLevel
        self.thinkingLevel = thinkingLevel
        self.supportedThinkingLevels = supportedThinkingLevels
        self.family = family
        self.maxOutput = maxOutput
        self.modelDescription = modelDescription
        self.inputCostPerMillion = inputCostPerMillion
        self.outputCostPerMillion = outputCostPerMillion
        self.recommended = recommended
        self.releaseDate = releaseDate
    }

    // MARK: - Formatted Display Helpers

    /// Formatted pricing string, e.g. "$3/M in · $15/M out"
    var formattedPricing: String? {
        guard let input = inputCostPerMillion, let output = outputCostPerMillion else { return nil }
        let fmtIn = input < 1 ? String(format: "$%.2f/M in", input) : "$\(Int(input))/M in"
        let fmtOut = output < 1 ? String(format: "$%.2f/M out", output) : "$\(Int(output))/M out"
        return "\(fmtIn) · \(fmtOut)"
    }

    /// Formatted max output, e.g. "128K output"
    var formattedMaxOutput: String? {
        guard let tokens = maxOutput ?? maxOutputTokens else { return nil }
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M output"
        } else if tokens >= 1_000 {
            return "\(tokens / 1_000)K output"
        }
        return "\(tokens) output"
    }

    /// Formatted context window, e.g. "200K context"
    var formattedContextWindow: String {
        if contextWindow >= 1_000_000 {
            return "\(contextWindow / 1_000_000)M context"
        } else if contextWindow >= 1_000 {
            return "\(contextWindow / 1_000)K context"
        }
        return "\(contextWindow) context"
    }

    /// Properly formatted display name (e.g., "Claude Opus 4.5", "Claude Sonnet 4")
    var displayName: String {
        // For OpenAI and MiniMax models, use the name directly
        if provider == "openai-codex" || provider == "openai" || provider == "minimax" {
            return name
        }
        return id.fullModelName
    }

    /// Short tier name: "Opus", "Sonnet", "Haiku"
    var shortName: String {
        // For OpenAI and MiniMax models, use the name directly
        if provider == "openai-codex" || provider == "openai" || provider == "minimax" {
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
        if lowerId.contains("minimax") {
            return name
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

    /// Whether this is a MiniMax model
    var isMiniMax: Bool {
        provider == "minimax"
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
