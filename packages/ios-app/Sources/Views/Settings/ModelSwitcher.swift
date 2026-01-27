import SwiftUI

// MARK: - Model Picker Menu (iOS 26 Liquid Glass Popup)

@available(iOS 26.0, *)
struct ModelPillLabel: View {
    let modelName: String
    /// When true, applies glassEffect directly to the label (for use inside Menu labels)
    var includeGlassEffect: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(TronTypography.pill)
            Text(modelName.shortModelName)
                .font(TronTypography.codeSM)
            Image(systemName: "chevron.up.chevron.down")
                .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
        }
        .foregroundStyle(.tronEmerald)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if includeGlassEffect {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: .capsule)
            }
        }
        .contentShape(Capsule())
    }
}

/// Popup menu for selecting models - replaces the old sheet-based picker
/// Organized by provider: Anthropic, OpenAI Codex, Google
/// Used inline in InputBar for fast model switching
@available(iOS 26.0, *)
struct ModelPickerMenu: View {
    let currentModel: String
    let models: [ModelInfo]
    let isLoading: Bool
    let onSelect: (ModelInfo) -> Void

    // PERFORMANCE: Cache filtered/sorted models to avoid recalculating on every render
    private var latestAnthropicModels: [ModelInfo] {
        models.filter { ($0.provider.lowercased() == "anthropic" || $0.id.lowercased().contains("claude")) && $0.is45Model }
            .uniqueByFormattedName().sortedByTier()
    }

    private var legacyAnthropicModels: [ModelInfo] {
        models.filter { ($0.provider.lowercased() == "anthropic" || $0.id.lowercased().contains("claude")) && !$0.is45Model }
            .uniqueByFormattedName().sortedByTier()
    }

    /// OpenAI Codex models (via ChatGPT subscription), sorted by version descending
    private var openAICodexModels: [ModelInfo] {
        models.filter { $0.provider.lowercased() == "openai-codex" }
            .sorted { m1, m2 in
                // Sort by version descending (5.2 before 5.1)
                codexVersionPriority(m1) > codexVersionPriority(m2)
            }
    }

    private func codexVersionPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("5.2") { return 52 }
        if id.contains("5.1") { return 51 }
        if id.contains("5.0") || id.contains("-5-") { return 50 }
        return 0
    }

    /// Standard OpenAI API models (gpt-4o, o1, o3, etc.)
    private var standardOpenAIModels: [ModelInfo] {
        models.filter { $0.provider.lowercased() == "openai" && !$0.provider.contains("codex") }
    }

    var body: some View {
        // DEBUG: Simplified Menu - just ForEach without computed properties
        Menu {
            Section("All Models") {
                ForEach(models) { model in
                    Button(model.formattedModelName) {
                        onSelect(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(TronTypography.pill)
                Text(currentModel.shortModelName)
                    .font(TronTypography.codeSM)
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            }
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: .capsule)
            }
            .contentShape(Capsule())
        }
    }

    // MARK: - Model Button

    @ViewBuilder
    private func modelButton(_ model: ModelInfo) -> some View {
        Button(model.formattedModelName) {
            onSelect(model)
        }
    }

    /// Codex model button with reasoning level indicator
    @ViewBuilder
    private func codexModelButton(_ model: ModelInfo) -> some View {
        Button {
            onSelect(model)
        } label: {
            HStack {
                Text(model.formattedModelName)
                if model.supportsReasoning == true {
                    Text("reasoning")
                        .font(TronTypography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

}

// MARK: - Array Extensions for Model Filtering

extension Array where Element == ModelInfo {
    /// Remove duplicate models by formatted name (keeps first occurrence)
    func uniqueByFormattedName() -> [ModelInfo] {
        ModelFilteringService.uniqueByFormattedName(self)
    }

    /// Sort by tier priority: Opus at top, then Sonnet, then Haiku
    /// Within same tier, sort by version descending (newer versions first)
    func sortedByTier() -> [ModelInfo] {
        ModelFilteringService.sortByTier(self)
    }
}

// MARK: - Model Switcher (Sheet-based)

struct ModelSwitcher: View {
    let rpcClient: RPCClient
    let currentModel: String
    let sessionId: String
    let onModelChanged: (String) -> Void
    /// Pre-loaded models from cache (optional - will fetch if nil)
    var cachedModels: [ModelInfo]?

    @Environment(\.dismiss) private var dismiss
    @State private var models: [ModelInfo] = []
    @State private var isLoading = true
    @State private var isSwitching = false
    @State private var selectedModelId: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .tint(.tronEmerald)
                } else {
                    modelList
                }
            }
            .navigationTitle("Switch Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        switchModel()
                    } label: {
                        if isSwitching {
                            ProgressView()
                                .tint(.tronEmerald)
                        } else {
                            Text("Switch")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(selectedModelId == currentModel || isSwitching)
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                selectedModelId = currentModel
                // Use cached models immediately if available
                if let cached = cachedModels, !cached.isEmpty {
                    models = cached
                    isLoading = false
                }
            }
            .task {
                // If we had cached models, refresh in background
                // Otherwise load synchronously (but still async)
                if cachedModels == nil || cachedModels?.isEmpty == true {
                    await loadModels()
                } else {
                    // Refresh in background without blocking UI
                    await refreshModelsInBackground()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var modelList: some View {
        List {
            // Group by tier
            ForEach(groupedModels, id: \.tier) { group in
                Section(group.tier) {
                    ForEach(group.models) { model in
                        ModelRow(
                            model: model,
                            isSelected: selectedModelId == model.id,
                            isCurrent: currentModel == model.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.tronFast) {
                                selectedModelId = model.id
                            }
                        }
                        .listRowBackground(
                            selectedModelId == model.id
                                ? Color.tronEmerald.opacity(0.2)
                                : Color.tronSurface
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var groupedModels: [ModelGroup] {
        ModelFilteringService.categorize(models)
    }

    private func loadModels() async {
        isLoading = true
        do {
            models = try await rpcClient.model.list()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Refresh models in background without showing loading indicator
    private func refreshModelsInBackground() async {
        do {
            let freshModels = try await rpcClient.model.list()
            // Only update if we got results
            if !freshModels.isEmpty {
                models = freshModels
            }
        } catch {
            // Silently fail - we have cached data
        }
    }

    private func switchModel() {
        guard selectedModelId != currentModel else { return }

        isSwitching = true
        Task {
            do {
                _ = try await rpcClient.model.switchModel(sessionId, model: selectedModelId)
                await MainActor.run {
                    onModelChanged(selectedModelId)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSwitching = false
                }
            }
        }
    }
}

// MARK: - Model Group

struct ModelGroup {
    let tier: String
    let models: [ModelInfo]
}

// MARK: - Model Row

struct ModelRow: View {
    let model: ModelInfo
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .tronEmerald : .tronTextMuted)
                .font(TronTypography.sans(size: TronTypography.sizeXL))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.formattedModelName)
                        .font(TronTypography.headline)
                        .foregroundStyle(.tronTextPrimary)

                    if isCurrent {
                        Text("Current")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronEmerald)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tronEmerald.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    if model.is45Model {
                        Text("Latest")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronEmerald)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tronEmerald.opacity(0.15))
                            .clipShape(Capsule())
                    } else if model.isLegacy == true {
                        Text("Legacy")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronTextMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tronTextMuted.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    // Preview badge for Gemini preview models
                    if model.isPreview {
                        Text("Preview")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 12) {
                    // Context window
                    Label(formatContextWindow(model.contextWindow), systemImage: "doc.text")

                    // Thinking support (Anthropic)
                    if model.supportsThinking == true {
                        Label("Thinking", systemImage: "brain")
                    }

                    // Reasoning support (OpenAI Codex)
                    if model.supportsReasoning == true {
                        Label("Reasoning", systemImage: "sparkles")
                    }

                    // Images support
                    if model.supportsImages == true {
                        Label("Vision", systemImage: "photo")
                    }
                }
                .font(TronTypography.caption)
                .foregroundStyle(.tronTextSecondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func formatContextWindow(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M ctx"
        } else if tokens >= 1_000 {
            return "\(tokens / 1_000)K ctx"
        }
        return "\(tokens) ctx"
    }
}

// MARK: - Preview

#Preview {
    ModelSwitcher(
        rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
        currentModel: "claude-sonnet-4-20250514",
        sessionId: "test",
        onModelChanged: { _ in },
        cachedModels: nil
    )
}
