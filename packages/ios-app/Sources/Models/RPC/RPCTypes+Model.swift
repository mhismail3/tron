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
    /// Sort order within provider (server-authoritative)
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, contextWindow, maxOutputTokens
        case supportsThinking, supportsImages, tier, isLegacy
        case supportsReasoning, reasoningLevels, defaultReasoningLevel
        case thinkingLevel, supportedThinkingLevels
        case family, maxOutput, recommended, releaseDate, sortOrder
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
        releaseDate: String? = nil,
        sortOrder: Int? = nil
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
        self.sortOrder = sortOrder
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

    /// Properly formatted display name (e.g., "Claude Opus 4.6", "Gemini 3 Pro")
    var displayName: String {
        isAnthropic ? "Claude \(name)" : name
    }

    /// Short tier name: "Opus", "Sonnet", "Haiku" (Anthropic), or full name for others
    var shortName: String {
        isAnthropic ? (tier?.capitalized ?? name) : name
    }

    /// Formatted model name for UI display
    var formattedModelName: String {
        isAnthropic ? "Claude \(name)" : name
    }

    /// Whether this is a latest generation model (server-driven via isLegacy flag)
    var isLatestGeneration: Bool {
        !(isLegacy ?? false)
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
        isGemini && (family ?? "").hasPrefix("Gemini 3")
    }

    /// Whether this is a preview model
    var isPreview: Bool {
        id.lowercased().contains("preview")
    }

    /// Gemini tier (pro, flash, flash-lite) — uses server-provided tier field
    var geminiTier: String? {
        isGemini ? tier : nil
    }
}

struct ModelListResult: Decodable {
    let models: [ModelInfo]
}
