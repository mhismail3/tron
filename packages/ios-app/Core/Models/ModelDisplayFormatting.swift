import Foundation

package enum ModelDisplayFormatting {
    private static let providerAliases: [String: String] = [
        "amazon-bedrock": "Amazon Bedrock",
        "anthropic": "Anthropic",
        "azure": "Azure OpenAI",
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

    private static let latestAliases: Set<String> = ["claude-haiku-4-5", "claude-opus-4-5", "claude-sonnet-4-5"]

    private static let wordAliases: [String: String] = [
        "ai": "AI",
        "api": "API",
        "deepseek": "DeepSeek",
        "github": "GitHub",
        "gpt": "GPT",
        "llm": "LLM",
        "lm": "LM",
        "openai": "OpenAI",
        "xai": "xAI"
    ]

    package static func provider(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Unknown provider" }
        let normalized = normalizeKey(clean)
        if let alias = providerAliases[normalized] { return alias }
        return words(in: clean).map(formatWord).joined(separator: " ")
    }

    package static func model(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Unknown model" }
        let key = normalizeKey(clean)
        let undated = ModelReleaseDate.pinnedReleaseDate(inID: key) == nil ? key : String(key.dropLast(9))
        var parts: [String] = []
        var joinsVersion = false, previousIsNumber = false
        for token in words(in: undated) {
            let isNumber = token.allSatisfy { $0.isASCII && $0.isNumber }
            let isVersion = isNumber && (token.count == 1 || token.count == 2 && !token.hasPrefix("0"))
            if isVersion, joinsVersion { parts[parts.count - 1] += ".\(token)" } else { parts.append(token) }
            joinsVersion = isVersion && (joinsVersion || !previousIsNumber)
            previousIsNumber = isNumber
        }
        let name = parts.map(formatWord).joined(separator: " ")
        return latestAliases.contains(key) ? "\(name) (latest)" : name
    }

    package static func reference(provider: String, model: String) -> String {
        "\(Self.provider(provider)) / \(Self.model(model))"
    }

    static func pickerIdentity(for model: ModelSummary) -> String {
        let identifier = "\(model.provider)/\(model.id)"
        if latestAliases.contains(model.id) {
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
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst().lowercased()
    }
}

package enum ModelReleaseDate {
    static func admits(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    package static func pinnedReleaseDate(inID id: String) -> String? {
        guard let match = id.range(of: #"-(\d{8})$"#, options: .regularExpression) else { return nil }
        let digits = id[match].dropFirst()
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
    }

    static func compact(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "")
    }
}

extension ModelRef {
    package var displayProviderName: String { ModelDisplayFormatting.provider(provider) }
    package var displayName: String { ModelDisplayFormatting.model(id) }
    package var displayDescription: String {
        ModelDisplayFormatting.reference(provider: provider, model: id)
    }
}

extension ProviderSummary {
    package var displayName: String {
        ModelDisplayFormatting.provider(name.isEmpty ? id : name)
    }
}

extension ModelSummary {
    package var pickerIdentity: String { ModelDisplayFormatting.pickerIdentity(for: self) }
    package var admittedReleaseDate: String? {
        releaseDate.flatMap { ModelReleaseDate.admits($0) ? $0 : nil }
    }
    package var displayProviderName: String { ModelDisplayFormatting.provider(provider) }
    package var displayName: String {
        ModelDisplayFormatting.model(name.isEmpty ? id : name)
    }
    var displayDescription: String {
        ModelDisplayFormatting.reference(provider: provider, model: name.isEmpty ? id : name)
    }
}

package enum ModelCardFacts {
    package static func priceLabel(_ price: ModelTokenPrice?) -> String? {
        guard let price else { return nil }
        return "\(dollars(price.input)) / \(dollars(price.output))"
    }

    package static func contextLabel(_ tokens: Int) -> String? {
        guard tokens > 0 else { return nil }
        if tokens >= 1_000_000 {
            let tenths = tokens / 100_000
            return tenths % 10 == 0 ? "\(tenths / 10)M" : "\(tenths / 10).\(tenths % 10)M"
        }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }

    package static func releaseLabel(_ date: String?) -> String? {
        guard let date, ModelReleaseDate.admits(date),
              let month = Int(date.dropFirst(5).prefix(2)), (1...12).contains(month) else { return nil }
        return "\(monthNames[month - 1]) \(date.prefix(4))"
    }

    package static func rowSummary(_ model: ModelSummary) -> String? {
        let parts = [
            contextLabel(model.contextWindow).map { "\($0) context" },
            priceLabel(model.cost),
            releaseLabel(model.releaseDate),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func dollars(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0" }
        if value < 0.01 { return "<$0.01" }
        let cents = (value * 100).rounded()
        return cents.truncatingRemainder(dividingBy: 100) == 0
            ? "$\(Int(cents / 100))"
            : String(format: "$%.2f", locale: posixLocale, cents / 100)
    }
}
