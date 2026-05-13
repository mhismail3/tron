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
    /// Canonical model ID when `id` may be an alias or snapshot.
    let canonicalModelId: String?
    let name: String
    let provider: String
    /// Active OpenAI endpoint profile (`codex` or `platform`) when provided.
    let apiEndpoint: String?
    /// Auth paths that this emitted model metadata applies to.
    let authPaths: [String]?
    /// Hidden aliases and snapshots accepted by the server.
    let aliasIds: [String]?
    /// Replacement model for retired aliases.
    let replacementModel: String?
    /// Whether the server hides this model from the default picker.
    let isHidden: Bool?
    let contextWindow: Int
    /// Maximum context window available through explicit opt-in, if different.
    let maxContextWindow: Int?
    let maxOutputTokens: Int?
    /// Whether the model emits thinking blocks. Required on the wire —
    /// every provider registry (Anthropic, OpenAI, Google, MiniMax, Kimi,
    /// Ollama) populates this explicitly. See I8.
    let supportsThinking: Bool
    /// Whether the model accepts image inputs. Required on the wire.
    let supportsImages: Bool
    /// Whether the model supports document inputs (PDFs, etc.). Required.
    let supportsDocuments: Bool
    /// Server-authoritative tier classification ("opus", "sonnet",
    /// "flagship", "flash", "local", …). Required on the wire — decoding
    /// a model payload without a tier is a server bug, not a client default.
    let tier: String
    /// Whether this model is a previous-generation release that the UI
    /// should de-prioritize. Required on the wire.
    let isRetiredGeneration: Bool
    /// Whether this model is retired and should not be selectable.
    let isRetired: Bool?
    /// Retirement date (YYYY-MM-DD) for display.
    let retirementDate: String?
    /// For models with reasoning capability (e.g., OpenAI)
    let supportsReasoning: Bool?
    /// Available reasoning effort levels (minimal, low, medium, high, xhigh)
    let reasoningLevels: [String]?
    /// Default reasoning level
    let defaultReasoningLevel: String?
    /// Whether OpenAI text verbosity controls are supported.
    let supportsVerbosity: Bool?
    /// Default OpenAI text verbosity for the active auth path.
    let defaultVerbosity: String?
    /// Whether the active OpenAI profile supports streaming Responses.
    let supportsStreaming: Bool?
    /// Whether the active profile supports provider-native capability invocation.
    let supportsCapabilityPrimitives: Bool?
    /// Whether the active OpenAI profile supports hosted capability search.
    let supportsCapabilitySearch: Bool?
    /// Whether the active OpenAI profile supports computer use.
    let supportsComputerUse: Bool?
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
    /// Human-readable provider name (server-authoritative, e.g. "Anthropic", "OpenAI")
    let providerDisplayName: String?
    /// Provider display order (server-authoritative, e.g. 0=Anthropic, 1=OpenAI)
    let providerSortOrder: Int?

    // MARK: - Availability (local providers like Ollama)

    /// Whether this model is available for use (Ollama: server running + model pulled)
    let available: Bool?
    /// Human-readable reason why the model is unavailable (e.g., install instructions)
    let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case id, canonicalModelId, name, provider, apiEndpoint, authPaths, aliasIds
        case replacementModel, isHidden, contextWindow, maxContextWindow, maxOutputTokens
        case supportsThinking, supportsImages, supportsDocuments, tier
        case isRetiredGeneration = "isLegacy"
        case isRetired = "isDeprecated"
        case retirementDate = "deprecationDate"
        case supportsReasoning, reasoningLevels, defaultReasoningLevel
        case supportsVerbosity, defaultVerbosity
        case supportsStreaming, supportsCapabilityPrimitives, supportsCapabilitySearch, supportsComputerUse
        case thinkingLevel, supportedThinkingLevels
        case family, maxOutput, recommended, releaseDate, sortOrder
        case providerDisplayName, providerSortOrder
        case inputCostPerMillion, outputCostPerMillion
        case modelDescription = "description"
        case available, unavailableReason
    }

    /// Explicit initializer used by tests and non-wire construction sites.
    /// The five required metadata fields (`supportsThinking`,
    /// `supportsImages`, `supportsDocuments`, `tier`, `isRetiredGeneration`) have no
    /// defaults — callers must pass them. Everything else is genuinely
    /// optional on the wire and defaults to nil here so test fixtures
    /// stay lean.
    init(
        id: String,
        canonicalModelId: String? = nil,
        name: String,
        provider: String,
        apiEndpoint: String? = nil,
        authPaths: [String]? = nil,
        aliasIds: [String]? = nil,
        replacementModel: String? = nil,
        isHidden: Bool? = nil,
        contextWindow: Int,
        maxContextWindow: Int? = nil,
        supportsThinking: Bool,
        supportsImages: Bool,
        supportsDocuments: Bool,
        tier: String,
        isRetiredGeneration: Bool,
        maxOutputTokens: Int? = nil,
        isRetired: Bool? = nil,
        retirementDate: String? = nil,
        supportsReasoning: Bool? = nil,
        reasoningLevels: [String]? = nil,
        defaultReasoningLevel: String? = nil,
        supportsVerbosity: Bool? = nil,
        defaultVerbosity: String? = nil,
        supportsStreaming: Bool? = nil,
        supportsCapabilityPrimitives: Bool? = nil,
        supportsCapabilitySearch: Bool? = nil,
        supportsComputerUse: Bool? = nil,
        thinkingLevel: String? = nil,
        supportedThinkingLevels: [String]? = nil,
        family: String? = nil,
        maxOutput: Int? = nil,
        modelDescription: String? = nil,
        inputCostPerMillion: Double? = nil,
        outputCostPerMillion: Double? = nil,
        recommended: Bool? = nil,
        releaseDate: String? = nil,
        sortOrder: Int? = nil,
        providerDisplayName: String? = nil,
        providerSortOrder: Int? = nil,
        available: Bool? = nil,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.canonicalModelId = canonicalModelId
        self.name = name
        self.provider = provider
        self.apiEndpoint = apiEndpoint
        self.authPaths = authPaths
        self.aliasIds = aliasIds
        self.replacementModel = replacementModel
        self.isHidden = isHidden
        self.contextWindow = contextWindow
        self.maxContextWindow = maxContextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsThinking = supportsThinking
        self.supportsImages = supportsImages
        self.supportsDocuments = supportsDocuments
        self.tier = tier
        self.isRetiredGeneration = isRetiredGeneration
        self.isRetired = isRetired
        self.retirementDate = retirementDate
        self.supportsReasoning = supportsReasoning
        self.reasoningLevels = reasoningLevels
        self.defaultReasoningLevel = defaultReasoningLevel
        self.supportsVerbosity = supportsVerbosity
        self.defaultVerbosity = defaultVerbosity
        self.supportsStreaming = supportsStreaming
        self.supportsCapabilityPrimitives = supportsCapabilityPrimitives
        self.supportsCapabilitySearch = supportsCapabilitySearch
        self.supportsComputerUse = supportsComputerUse
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
        self.providerDisplayName = providerDisplayName
        self.providerSortOrder = providerSortOrder
        self.available = available
        self.unavailableReason = unavailableReason
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
        isAnthropic ? tier.capitalized : name
    }

    /// Formatted model name for UI display (delegates to `displayName`)
    var formattedModelName: String { displayName }

    /// Whether this is a latest generation model (server-driven via retired-generation field)
    var isLatestGeneration: Bool {
        !isRetiredGeneration
    }

    /// Whether this model is retired.
    var isRetiredModel: Bool {
        isRetired ?? false
    }

    /// Whether this model is unavailable (local provider not running or model not pulled)
    var isUnavailable: Bool {
        available == false
    }

    /// Whether selecting this model should put the harness into local profile mode.
    var isLocalProvider: Bool {
        provider.lowercased() == "ollama" || tier.lowercased() == "local"
    }

    /// Whether this model should be disabled in the picker.
    var isDisabled: Bool {
        isRetiredModel || isUnavailable
    }

    /// Whether this is an Anthropic model
    var isAnthropic: Bool {
        provider == "anthropic"
    }

    /// Whether this is an OpenAI model exposed through Tron's OpenAI provider.
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

    /// Whether this is a Kimi model
    var isKimi: Bool {
        provider == "kimi"
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

    /// Provider-specific image processing limits.
    var providerImageLimits: ProviderImageLimits {
        if isAnthropic { return .anthropic }
        if isCodex { return .openai }
        if isGemini { return .gemini }
        if isKimi { return .kimi }
        return .default
    }
}

struct ModelListResult: Decodable {
    let models: [ModelInfo]
}

// MARK: - Reasoning Level

struct ReasoningLevelParams: Encodable {
    let sessionId: String
    let level: String
}

struct ReasoningLevelResult: Decodable {
    let previousLevel: String?
    let newLevel: String
    let changed: Bool
}
