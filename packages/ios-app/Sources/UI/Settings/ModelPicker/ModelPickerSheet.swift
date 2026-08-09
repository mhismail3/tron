import SwiftUI

// MARK: - Model Picker Sheet

/// Rich bottom sheet for model selection with Provider > Family > Model hierarchy.
/// Uses the standard settings sheet shell: NavigationStack, ScrollView, collapsible sections.
struct ModelPickerSheet: View {
    let models: [ModelInfo]
    let currentModelId: String
    var readOnly: Bool = false
    var reasoningLevel: String?
    let onSelect: (ModelInfo) -> Void
    var onSelectReasoning: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedProviders: Set<String> = []
    @State private var expandedFamilies: Set<String> = []
    @State private var expandedDetails: Set<String> = []
    @State private var pendingModelId: String = ""
    @State private var pendingReasoningLevel: String?
    @State private var didSelectReasoningLevel = false
    @State private var hasCommitted = false

    private var providerGroups: [ProviderGroup] {
        ModelFilteringService.organizeByProviderFamily(models)
    }

    /// Uses pending selection so toolbar updates live as user browses
    private var selectedModelInfo: ModelInfo? {
        let id = pendingModelId.isEmpty ? currentModelId : pendingModelId
        return models.first { $0.id == id }
    }

    private var supportsReasoning: Bool {
        ModelPickerReasoningVisibility.showsReasoningControl(
            selectedModel: selectedModelInfo,
            allowsSelection: !readOnly && onSelectReasoning != nil
        )
    }

    private var availableReasoningLevels: [String] {
        selectedModelInfo?.reasoningLevels?.reduce(into: [String]()) { result, level in
            guard !level.isEmpty, !result.contains(level) else { return }
            result.append(level)
        } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(providerGroups) { provider in
                            ProviderSection(
                                provider: provider,
                                accentColor: displayColor(for: provider),
                                currentModelId: pendingModelId.isEmpty ? currentModelId : pendingModelId,
                                readOnly: readOnly,
                                isExpanded: expandedProviders.contains(provider.id),
                                expandedFamilies: $expandedFamilies,
                                expandedDetails: $expandedDetails,
                                onToggle: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        if expandedProviders.contains(provider.id) {
                                            expandedProviders.remove(provider.id)
                                        } else {
                                            expandedProviders.insert(provider.id)
                                        }
                                    }
                                },
                                onSelect: { model in
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        pendingModelId = model.id
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical)
                }
                .task(id: currentModelId) {
                    await Task.yield()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        proxy.scrollTo(currentModelId, anchor: .center)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if supportsReasoning {
                        reasoningButton
                    }
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Models", color: ModelPickerPresentation.primaryAccent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { commitSelection(); dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(ModelPickerPresentation.primaryAccent)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(ModelPickerPresentation.primaryAccent)
        .onDisappear {
            commitSelection()
        }
        .onAppear {
            pendingModelId = currentModelId
            pendingReasoningLevel = ModelPickerReasoningVisibility.normalizedLevel(
                reasoningLevel,
                for: selectedModelInfo
            )
            // Expand the provider and family containing the currently selected
            // model so its row is visible on open. Also keep each provider's
            // "latest" family expanded as a helpful default for browsing.
            for provider in providerGroups {
                for family in provider.families {
                    let containsSelected = family.models.contains { $0.id == currentModelId }
                    if containsSelected {
                        expandedProviders.insert(provider.id)
                        expandedFamilies.insert(family.id)
                    }
                    if family.isLatest {
                        expandedFamilies.insert(family.id)
                    }
                }
            }
        }
        .onChange(of: pendingModelId) { _, _ in
            pendingReasoningLevel = ModelPickerReasoningVisibility.normalizedLevel(
                pendingReasoningLevel,
                for: selectedModelInfo
            )
        }
    }

    // MARK: - Reasoning Button

    private var reasoningButton: some View {
        let currentReasoningLevel = pendingReasoningLevel
            ?? availableReasoningLevels.first
            ?? ""
        return Menu {
            ForEach(availableReasoningLevels, id: \.self) { level in
                Button {
                    pendingReasoningLevel = level
                    didSelectReasoningLevel = true
                } label: {
                    Label {
                        Text(reasoningLevelLabel(level))
                    } icon: {
                        Image(systemName: level == currentReasoningLevel
                            ? "checkmark"
                            : Color.reasoningLevelIcon(level))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: Color.reasoningLevelIcon(currentReasoningLevel))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                Text(reasoningLevelLabel(currentReasoningLevel))
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(ModelPickerPresentation.primaryAccent)
        }
        .menuOrder(.fixed)
    }

    private func reasoningLevelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.capitalized
        }
    }

    private func displayColor(for provider: ProviderGroup) -> Color {
        ModelPickerPresentation.usesHighContrastNeutral(
            providerId: provider.id,
            isDark: colorScheme == .dark
        ) ? .tronTextSecondary : provider.color
    }

    private func commitSelection() {
        guard !hasCommitted else { return }
        hasCommitted = true
        if pendingModelId != currentModelId,
           let model = models.first(where: { $0.id == pendingModelId }) {
            onSelect(model)
        }
        let modelChanged = pendingModelId != currentModelId
        if let pendingReasoningLevel,
           (modelChanged || didSelectReasoningLevel),
           pendingReasoningLevel != reasoningLevel {
            onSelectReasoning?(pendingReasoningLevel)
        }
    }
}
