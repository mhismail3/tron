import SwiftUI

// MARK: - Model Switcher

struct ModelSwitcher: View {
    let rpcClient: RPCClient
    let currentModel: String
    let sessionId: String
    let onModelChanged: (String) -> Void

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
            .task {
                await loadModels()
            }
            .onAppear {
                selectedModelId = currentModel
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
        let tiers = ["opus", "sonnet", "haiku"]
        var groups: [ModelGroup] = []

        for tier in tiers {
            let tierModels = models.filter { model in
                model.id.lowercased().contains(tier)
            }.sorted { m1, m2 in
                // Sort by non-legacy first, then by name
                if (m1.isLegacy ?? false) != (m2.isLegacy ?? false) {
                    return !(m1.isLegacy ?? false)
                }
                return m1.id > m2.id // Newer models first
            }

            if !tierModels.isEmpty {
                groups.append(ModelGroup(tier: tier.capitalized, models: tierModels))
            }
        }

        return groups
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
                    Text(model.name)
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

                    if model.isLegacy == true {
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
        onModelChanged: { _ in }
    )
}
