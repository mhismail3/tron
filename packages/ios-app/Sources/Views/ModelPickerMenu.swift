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

    /// OpenAI Codex models - sorted by version descending (5.2 before 5.1)
    private var codexModels: [ModelInfo] {
        models.filter { $0.isCodex }
            .sorted { codexVersionPriority($0) > codexVersionPriority($1) }
    }

    /// Legacy Anthropic models (non-4.5) - sorted: Opus → Sonnet
    private var legacyModels: [ModelInfo] {
        models.filter { $0.isAnthropic && !$0.is45Model }
            .uniqueByFormattedName()
            .sortedByTier()
    }

    private func codexVersionPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("5.2") { return 52 }
        if id.contains("5.1") { return 51 }
        if id.contains("5.0") || id.contains("-5-") { return 50 }
        return 0
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

                // Divider before Codex models
                if !codexModels.isEmpty {
                    Divider()
                    ForEach(codexModels) { model in
                        modelButton(model: model, systemImage: "bolt")
                    }
                }

                // Divider before legacy models
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
