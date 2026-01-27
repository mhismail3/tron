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

    // MARK: - Model Categorization (via ModelFilteringService)

    private var modelGroups: [ModelGroup] {
        ModelFilteringService.categorize(models)
    }

    private var latestAnthropicModels: [ModelInfo] {
        modelGroups.first { $0.tier == "Anthropic (Latest)" }?.models ?? []
    }

    private var latestCodexModels: [ModelInfo] {
        modelGroups.first { $0.tier == "OpenAI Codex (Latest)" }?.models ?? []
    }

    private var gemini3Models: [ModelInfo] {
        modelGroups.first { $0.tier == "Gemini 3" }?.models ?? []
    }

    private var legacyModels: [ModelInfo] {
        modelGroups.first { $0.tier == "Legacy" }?.models ?? []
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
