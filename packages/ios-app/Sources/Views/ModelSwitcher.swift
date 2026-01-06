import SwiftUI

// MARK: - Model Picker Menu (iOS 26 Liquid Glass Popup)

/// Popup menu for selecting models - replaces the old sheet-based picker
/// Used inline in InputBar for fast model switching
@available(iOS 26.0, *)
struct ModelPickerMenu: View {
    let currentModel: String
    let models: [ModelInfo]
    let isLoading: Bool
    let onSelect: (ModelInfo) -> Void

    var body: some View {
        Menu {
            if isLoading && models.isEmpty {
                Text("Loading models...")
            } else {
                // Latest 4.5 models section
                let latestModels = models.filter { $0.is45Model }.uniqueByFormattedName().sortedByTier()
                if !latestModels.isEmpty {
                    Section("Latest") {
                        ForEach(latestModels) { model in
                            modelButton(model)
                        }
                    }
                }

                // Claude 4 models section (non-4.5)
                let claude4Models = models.filter { isClaude4NotLatest($0) }.uniqueByFormattedName().sortedByTier()
                if !claude4Models.isEmpty {
                    Section("Claude 4") {
                        ForEach(claude4Models) { model in
                            modelButton(model)
                        }
                    }
                }

                // Coming Soon - OpenAI and Gemini placeholders
                Section("Coming Soon") {
                    // OpenAI models
                    disabledModelRow("GPT-5.2", provider: "OpenAI")
                    disabledModelRow("GPT-5.2 Mini", provider: "OpenAI")
                    disabledModelRow("o3", provider: "OpenAI")
                    disabledModelRow("o4-mini", provider: "OpenAI")
                    disabledModelRow("Codex", provider: "OpenAI")

                    // Gemini models
                    disabledModelRow("Gemini 2.5 Pro", provider: "Google")
                    disabledModelRow("Gemini 2.5 Flash", provider: "Google")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .medium))
                Text(currentModel.shortModelName)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.4)).interactive(), in: .capsule)
    }

    @ViewBuilder
    private func modelButton(_ model: ModelInfo) -> some View {
        Button {
            onSelect(model)
        } label: {
            HStack {
                Text(model.formattedModelName)
                if model.id == currentModel {
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
        .disabled(model.id == currentModel)
    }

    @ViewBuilder
    private func disabledModelRow(_ name: String, provider: String) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(provider)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .disabled(true)
    }

    /// Check if model is Claude 4 but not 4.5
    private func isClaude4NotLatest(_ model: ModelInfo) -> Bool {
        let lowerId = model.id.lowercased()
        // Is Claude 4 (has -4- or ends with -4) but not 4.5
        let isClaude4 = (lowerId.contains("-4-") || lowerId.contains("sonnet-4") || lowerId.contains("opus-4") || lowerId.contains("haiku-4"))
        let is45 = lowerId.contains("4-5") || lowerId.contains("4.5")
        return isClaude4 && !is45
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
        // Separate 4.5 models (latest) from legacy models
        let latestModels = models.filter { is45Model($0) }
        let legacyModels = models.filter { !is45Model($0) }

        var groups: [ModelGroup] = []

        // Latest 4.5 models first - ordered by tier: Opus, Sonnet, Haiku
        let orderedLatest = latestModels.sorted { m1, m2 in
            tierPriority(m1) < tierPriority(m2)
        }

        if !orderedLatest.isEmpty {
            groups.append(ModelGroup(tier: "Latest (4.5)", models: orderedLatest))
        }

        // Legacy models grouped by tier
        let tiers = ["opus", "sonnet", "haiku"]
        for tier in tiers {
            let tierModels = legacyModels.filter { model in
                model.id.lowercased().contains(tier)
            }.sorted { $0.id > $1.id }

            if !tierModels.isEmpty {
                groups.append(ModelGroup(tier: "\(tier.capitalized) (Legacy)", models: tierModels))
            }
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

                    // Thinking support
                    if model.supportsThinking == true {
                        Label("Thinking", systemImage: "brain")
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
