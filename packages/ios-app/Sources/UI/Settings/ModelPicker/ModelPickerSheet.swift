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

    @Environment(\.dismiss) private var dismiss
    @State private var expandedProviders: Set<String> = []
    @State private var expandedFamilies: Set<String> = []
    @State private var expandedDetails: Set<String> = []
    @State private var showReasoningPopover = false
    @State private var pendingModelId: String = ""
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
            reasoningLevel: reasoningLevel
        )
    }

    private var availableReasoningLevels: [String] {
        selectedModelInfo?.reasoningLevels ?? ["minimal", "low", "medium", "high", "xhigh"]
    }

    /// Provider color for the currently selected model
    private var selectedProviderColor: Color {
        guard let model = selectedModelInfo else { return .tronEmerald }
        for group in providerGroups {
            let contains = group.families.contains { $0.models.contains { $0.id == model.id } }
            if contains { return group.color }
        }
        return .tronEmerald
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(providerGroups) { provider in
                            ProviderSection(
                                provider: provider,
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
                .onAppear {
                    // Defer scroll until after expansion layout settles
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            proxy.scrollTo(currentModelId, anchor: .center)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if supportsReasoning {
                        reasoningButton
                    }
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Models", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { commitSelection(); dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronPurple)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .onDisappear {
            commitSelection()
        }
        .onAppear {
            pendingModelId = currentModelId
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
    }

    // MARK: - Reasoning Button

    private var reasoningButton: some View {
        let currentReasoningLevel = reasoningLevel ?? "medium"
        return Button {
            showReasoningPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: Color.reasoningLevelIcon(currentReasoningLevel))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                Text(reasoningLevelLabel(currentReasoningLevel))
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(selectedProviderColor)
        }
        .popover(isPresented: $showReasoningPopover, arrowEdge: .top) {
            ReasoningLevelPopover(
                levels: availableReasoningLevels,
                currentLevel: currentReasoningLevel,
                accentColor: selectedProviderColor,
                onSelect: { level in
                    showReasoningPopover = false
                    NotificationCenter.default.post(name: .reasoningLevelAction, object: level)
                }
            )
            .popoverCompactAdaptation()
        }
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

    private func commitSelection() {
        guard !hasCommitted else { return }
        guard pendingModelId != currentModelId,
              let model = models.first(where: { $0.id == pendingModelId }) else { return }
        hasCommitted = true
        onSelect(model)
    }
}
