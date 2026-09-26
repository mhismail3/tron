import Foundation

enum ModelDisplayFormatting {
    private static let providerAliases: [String: String] = [
        "amazon-bedrock": "Amazon Bedrock",
        "anthropic": "Anthropic",
        "anthropic-(cortexkit)": "Anthropic (CortexKit)",
        "azure-openai": "Azure OpenAI",
        "deepseek": "DeepSeek",
        "github-copilot": "GitHub Copilot",
        "google": "Google",
        "google-gemini": "Google Gemini",
        "groq": "Groq",
        "lm-studio": "LM Studio",
        "mistral": "Mistral",
        "ollama": "Ollama",
        "openai": "OpenAI",
        "openai-codex": "OpenAI Codex",
        "openrouter": "OpenRouter",
        "together-ai": "Together AI",
        "vertex-ai": "Vertex AI",
        "xai": "xAI"
    ]

    // ModelRef carries only an ID; catalog rows use the SDK's authoritative name instead.
    private static let modelAliases: [String: String] = [
        "claude-fable-5-1": "Claude Fable 5.1",
        "claude-haiku-4-5": "Claude Haiku 4.5 (latest)",
        "claude-haiku-4-5-20251001": "Claude Haiku 4.5",
        "claude-mythos-5-1": "Claude Mythos 5.1",
        "claude-opus-4-5": "Claude Opus 4.5 (latest)",
        "claude-opus-4-5-20251101": "Claude Opus 4.5",
        "claude-opus-4-8": "Claude Opus 4.8",
        "claude-opus-5-5": "Claude Opus 5.5",
        "claude-sonnet-4-5": "Claude Sonnet 4.5 (latest)",
        "claude-sonnet-4-5-20250929": "Claude Sonnet 4.5",
        "claude-sonnet-5": "Claude Sonnet 5"
    ]

    private static let wordAliases: [String: String] = [
        "ai": "AI",
        "api": "API",
        "codex": "Codex",
        "claude": "Claude",
        "deepseek": "DeepSeek",
        "gemini": "Gemini",
        "github": "GitHub",
        "gpt": "GPT",
        "llama": "Llama",
        "llm": "LLM",
        "lm": "LM",
        "mistral": "Mistral",
        "openai": "OpenAI",
        "opus": "Opus",
        "qwen": "Qwen",
        "sonnet": "Sonnet",
        "haiku": "Haiku",
        "xai": "xAI"
    ]

    static func provider(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Unknown provider" }
        let normalized = normalizeKey(clean)
        if let alias = providerAliases[normalized] { return alias }
        return words(in: clean).map(formatWord).joined(separator: " ")
    }

    static func model(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Unknown model" }
        if let alias = modelAliases[normalizeKey(clean)] { return alias }
        return words(in: clean).map(formatWord).joined(separator: " ")
    }

    static func reference(provider: String, model: String) -> String {
        "\(Self.provider(provider)) / \(Self.model(model))"
    }

    static func pickerIdentity(for model: ModelSummary) -> String {
        let identifier = "\(model.provider)/\(model.id)"
        if ["claude-haiku-4-5", "claude-opus-4-5", "claude-sonnet-4-5"].contains(model.id) {
            return "Latest alias · \(identifier)"
        }
        if let date = ModelReleaseDate.pinnedReleaseDate(inID: model.id) {
            return "Pinned release · \(date) · \(identifier)"
        }
        return "Model ID · \(identifier)"
    }

    private static func normalizeKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .joined(separator: "-")
    }

    private static func words(in value: String) -> [String] {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func formatWord(_ value: String) -> String {
        let normalized = value.lowercased()
        if let alias = wordAliases[normalized] { return alias }
        if normalized.first == "o", normalized.dropFirst().allSatisfy(\.isNumber) {
            return normalized.prefix(1).uppercased() + normalized.dropFirst()
        }
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst().lowercased()
    }
}

/// The one spelling of model release-date syntax. Gateway payloads, the
/// "Pinned release" identity line, and the Latest rail all read it here so the
/// wire format cannot drift between them.
enum ModelReleaseDate {
    static func admits(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// The date pinned by a date-suffixed model ID, e.g.
    /// `claude-opus-4-5-20251101` becomes `2025-11-01`. Nil without a suffix.
    static func pinnedReleaseDate(inID id: String) -> String? {
        guard let match = id.range(of: #"-(\d{8})$"#, options: .regularExpression) else { return nil }
        let digits = id[match].dropFirst()
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
    }

    /// `2025-11-01` to `20251101`, the ID suffix that pins that release.
    static func compact(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "")
    }
}

extension ModelRef {
    var displayProviderName: String { ModelDisplayFormatting.provider(provider) }
    var displayName: String { ModelDisplayFormatting.model(id) }
    var displayDescription: String {
        ModelDisplayFormatting.reference(provider: provider, model: id)
    }
}

extension ProviderSummary {
    var displayName: String {
        ModelDisplayFormatting.provider(name.isEmpty ? id : name)
    }
}

extension ModelSummary {
    var pickerIdentity: String { ModelDisplayFormatting.pickerIdentity(for: self) }
    /// The release date the picker may order by. A malformed or absent Gateway
    /// value keeps the model out of the Latest rail instead of failing the
    /// catalog read; the raw value stays canonical.
    var admittedReleaseDate: String? {
        releaseDate.flatMap { ModelReleaseDate.admits($0) ? $0 : nil }
    }
    var displayProviderName: String { ModelDisplayFormatting.provider(provider) }
    var displayName: String {
        ModelDisplayFormatting.model(name.isEmpty ? id : name)
    }
    var displayDescription: String {
        ModelDisplayFormatting.reference(provider: provider, model: name.isEmpty ? id : name)
    }
}
