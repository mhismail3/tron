import SwiftUI

// MARK: - Shared Model Picker Menu Content

/// Shared model picker menu content used by both NewSessionFlow and InputBar
/// Provides consistent model categorization and display across the app
@available(iOS 26.0, *)
struct ModelPickerMenuContent<Label: View>: View {
    let models: [ModelInfo]
    let isLoading: Bool
    let onModelSelected: (ModelInfo) -> Void
    let label: () -> Label

    init(
        models: [ModelInfo],
        isLoading: Bool = false,
        onModelSelected: @escaping (ModelInfo) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.models = models
        self.isLoading = isLoading
        self.onModelSelected = onModelSelected
        self.label = label
    }

    // MARK: - Model Categorization

    /// Anthropic 4.5 models (latest) - sorted: Opus (top) → Sonnet → Haiku (bottom)
    private var latestAnthropicModels: [ModelInfo] {
        models.filter { $0.isAnthropic && $0.is45Model }
            .uniqueByFormattedName()
            .sortedByTier()
    }

    /// Latest OpenAI Codex models (5.2 only) - sorted by tier
    private var latestCodexModels: [ModelInfo] {
        models.filter { $0.isCodex && $0.id.lowercased().contains("5.2") }
    }

    /// Gemini 3 models (latest Google models) - sorted: Pro → Flash → Flash Lite
    private var gemini3Models: [ModelInfo] {
        models.filter { $0.isGemini && $0.isGemini3 }
            .sorted { geminiTierPriority($0) < geminiTierPriority($1) }
    }

    /// Legacy models: legacy Anthropic (non-4.5) + Codex 5.1 + Gemini 2.5
    private var legacyModels: [ModelInfo] {
        let legacyAnthropic = models.filter { $0.isAnthropic && !$0.is45Model }
            .uniqueByFormattedName()
            .sortedByTier()
        let legacyCodex = models.filter { $0.isCodex && !$0.id.lowercased().contains("5.2") }
        let legacyGemini = models.filter { $0.isGemini && !$0.isGemini3 }
            .sorted { geminiTierPriority($0) < geminiTierPriority($1) }
        return legacyAnthropic + legacyCodex + legacyGemini
    }

    /// Sort Gemini models: Pro first, then Flash, then Flash Lite
    private func geminiTierPriority(_ model: ModelInfo) -> Int {
        switch model.geminiTier {
        case "pro": return 0
        case "flash": return 1
        case "flash-lite": return 2
        default: return 3
        }
    }

    // MARK: - Body

    var body: some View {
        Menu {
            if isLoading && models.isEmpty {
                Text("Loading models...")
            } else {
                // Latest Anthropic models (4.5)
                ForEach(latestAnthropicModels) { model in
                    modelButton(model: model, systemImage: "sparkles")
                }

                // Latest OpenAI Codex models (5.2)
                if !latestCodexModels.isEmpty {
                    Divider()
                    ForEach(latestCodexModels) { model in
                        modelButton(model: model, systemImage: "bolt")
                    }
                }

                // Gemini 3 models (latest Google models)
                if !gemini3Models.isEmpty {
                    Divider()
                    ForEach(gemini3Models) { model in
                        modelButton(model: model, systemImage: "atom")
                    }
                }

                // Legacy models (legacy Anthropic + Codex 5.1 + Gemini 2.5)
                if !legacyModels.isEmpty {
                    Divider()
                    ForEach(legacyModels) { model in
                        modelButton(model: model, systemImage: "clock")
                    }
                }
            }
        } label: {
            label()
        }
    }

    @ViewBuilder
    private func modelButton(model: ModelInfo, systemImage: String) -> some View {
        Button {
            onModelSelected(model)
        } label: {
            SwiftUI.Label(model.formattedModelName, systemImage: systemImage)
        }
    }
}

// MARK: - Convenience Initializers

@available(iOS 26.0, *)
extension ModelPickerMenuContent {
    /// Creates a model picker with a binding to the selected model ID
    init(
        models: [ModelInfo],
        selectedModelId: Binding<String>,
        isLoading: Bool = false,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.init(
            models: models,
            isLoading: isLoading,
            onModelSelected: { selectedModelId.wrappedValue = $0.id },
            label: label
        )
    }

    /// Creates a model picker that posts to NotificationCenter (for InputBar usage)
    init(
        models: [ModelInfo],
        notificationName: Notification.Name,
        isLoading: Bool = false,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.init(
            models: models,
            isLoading: isLoading,
            onModelSelected: { NotificationCenter.default.post(name: notificationName, object: $0) },
            label: label
        )
    }
}
