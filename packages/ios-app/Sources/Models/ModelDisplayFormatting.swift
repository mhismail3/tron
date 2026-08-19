import Foundation

enum ModelDisplayFormatting {
    private static let providerAliases: [String: String] = [
        "amazon-bedrock": "Amazon Bedrock",
        "anthropic": "Anthropic",
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
        return words(in: clean).map(formatWord).joined(separator: " ")
    }

    static func reference(provider: String, model: String) -> String {
        "\(Self.provider(provider)) / \(Self.model(model))"
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
    var displayProviderName: String { ModelDisplayFormatting.provider(provider) }
    var displayName: String {
        ModelDisplayFormatting.model(name.isEmpty ? id : name)
    }
    var displayDescription: String {
        ModelDisplayFormatting.reference(provider: provider, model: name.isEmpty ? id : name)
    }
}
