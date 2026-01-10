import SwiftUI

// MARK: - Model Picker Menu (iOS 26 Liquid Glass Popup)

@available(iOS 26.0, *)
struct ModelPillLabel: View {
    let modelName: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .medium))
            Text(modelName.shortModelName)
                .font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(.tronEmerald)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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

    /// OpenAI Codex models (via ChatGPT subscription)
    private var openAICodexModels: [ModelInfo] {
        models.filter { $0.provider.lowercased() == "openai-codex" }
    }

    /// Standard OpenAI API models (gpt-4o, o1, o3, etc.)
    private var standardOpenAIModels: [ModelInfo] {
        models.filter { $0.provider.lowercased() == "openai" && !$0.provider.contains("codex") }
    }

    var body: some View {
        Menu {
            if isLoading && models.isEmpty {
                Text("Loading models...")
            } else {
                // Order (top to bottom): Legacy, Coming Soon, OpenAI Codex, Anthropic
                // Latest models at bottom, closest to user's thumb

                // Legacy Anthropic models (top)
                if !legacyAnthropicModels.isEmpty {
                    Section("Legacy") {
                        ForEach(legacyAnthropicModels) { model in
                            modelButton(model)
                        }
                    }
                }

                // Coming Soon (disabled models)
                Section("Coming Soon") {
                    ForEach(standardOpenAIModels) { model in
                        modelButton(model)
                    }
                    if standardOpenAIModels.isEmpty {
                        comingSoonModel("GPT-4o")
                        comingSoonModel("o3")
                        comingSoonModel("o3-mini")
                    }
                    comingSoonModel("Gemini 3 Pro")
                    comingSoonModel("Gemini 3 Flash")
                }

                // OpenAI Codex (ChatGPT subscription models)
                Section("OpenAI Codex") {
                    ForEach(openAICodexModels) { model in
                        codexModelButton(model)
                    }
                    if openAICodexModels.isEmpty {
                        comingSoonModel("GPT-5.2 Codex")
                    }
                }

                // Anthropic 4.5 family (bottom, closest to thumb)
                Section("Anthropic") {
                    ForEach(latestAnthropicModels) { model in
                        modelButton(model)
                    }
                }
            }
        } label: {
            ModelPillLabel(modelName: currentModel)
        }
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.4)).interactive(), in: .capsule)
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Coming Soon Model (greyed out, disabled)

    @ViewBuilder
    private func comingSoonModel(_ name: String) -> some View {
        Text(name)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Array Extensions for Model Filtering

extension Array where Element == ModelInfo {
    /// Remove duplicate models by formatted name (keeps first occurrence)
    func uniqueByFormattedName() -> [ModelInfo] {
        var seen = Set<String>()
        return filter { model in
            let name = model.formattedModelName
            if seen.contains(name) {
                return false
            }
            seen.insert(name)
            return true
        }
    }

    /// Sort by tier priority: Opus > Sonnet > Haiku
    func sortedByTier() -> [ModelInfo] {
        sorted { m1, m2 in
            tierPriority(m1) < tierPriority(m2)
        }
    }

    private func tierPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("opus") { return 0 }
        if id.contains("sonnet") { return 1 }
        if id.contains("haiku") { return 2 }
        return 3
    }
}

// MARK: - Legacy Model Switcher (Sheet-based, kept for reference)

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
        // Separate models by provider
        let anthropicModels = models.filter { $0.isAnthropic }
        let codexModels = models.filter { $0.isCodex }

        // Further separate Anthropic: 4.5 models (latest) from legacy models
        let latestAnthropicModels = anthropicModels.filter { is45Model($0) }
        let legacyAnthropicModels = anthropicModels.filter { !is45Model($0) }

        var groups: [ModelGroup] = []

        // Latest 4.5 Anthropic models first - ordered by tier: Opus, Sonnet, Haiku
        let orderedLatest = latestAnthropicModels.sorted { m1, m2 in
            tierPriority(m1) < tierPriority(m2)
        }

        if !orderedLatest.isEmpty {
            groups.append(ModelGroup(tier: "Anthropic (Latest)", models: orderedLatest))
        }

        // Legacy Anthropic models grouped by tier
        let tiers = ["opus", "sonnet", "haiku"]
        for tier in tiers {
            let tierModels = legacyAnthropicModels.filter { model in
                model.id.lowercased().contains(tier)
            }.sorted { $0.id > $1.id }

            if !tierModels.isEmpty {
                groups.append(ModelGroup(tier: "\(tier.capitalized) (Legacy)", models: tierModels))
            }
        }

        // OpenAI Codex models
        if !codexModels.isEmpty {
            groups.append(ModelGroup(tier: "OpenAI Codex", models: codexModels))
        }

        return groups
    }

    private func is45Model(_ model: ModelInfo) -> Bool {
        let id = model.id.lowercased()
        return id.contains("4-5") || id.contains("4.5") || id.contains("opus-4-5") || id.contains("sonnet-4-5") || id.contains("haiku-4-5")
    }

    private func tierPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("opus") { return 0 }
        if id.contains("sonnet") { return 1 }
        if id.contains("haiku") { return 2 }
        return 3
    }

    private func loadModels() async {
        isLoading = true
        do {
            models = try await rpcClient.listModels()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Refresh models in background without showing loading indicator
    private func refreshModelsInBackground() async {
        do {
            let freshModels = try await rpcClient.listModels()
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
                _ = try await rpcClient.switchModel(sessionId, model: selectedModelId)
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
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.formattedModelName)
                        .font(.headline)
                        .foregroundStyle(.tronTextPrimary)

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tronEmerald)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tronEmerald.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    if model.is45Model {
                        Text("Latest")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tronEmerald)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tronEmerald.opacity(0.15))
                            .clipShape(Capsule())
                    } else if model.isLegacy == true {
                        Text("Legacy")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tronTextMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tronTextMuted.opacity(0.2))
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
                .font(.caption)
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
