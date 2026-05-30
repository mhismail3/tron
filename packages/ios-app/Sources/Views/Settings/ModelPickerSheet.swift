import SwiftUI

// MARK: - Model Picker Sheet

/// Rich bottom sheet for model selection with Provider > Family > Model hierarchy.
/// Follows AgentControlView patterns: NavigationStack, ScrollView, collapsible sections.
@available(iOS 26.0, *)
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
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
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
            .presentationCompactAdaptation(.popover)
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

enum ModelPickerReasoningVisibility {
    static func showsReasoningControl(selectedModel: ModelInfo?, reasoningLevel: String?) -> Bool {
        reasoningLevel != nil && selectedModel?.supportsReasoning == true
    }
}

// MARK: - Provider Section

@available(iOS 26.0, *)
private struct ProviderSection: View {
    let provider: ProviderGroup
    let currentModelId: String
    let readOnly: Bool
    let isExpanded: Bool
    @Binding var expandedFamilies: Set<String>
    @Binding var expandedDetails: Set<String>
    let onToggle: () -> Void
    let onSelect: (ModelInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Provider header
            HStack(spacing: 8) {
                Image(provider.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(provider.color)
                    .frame(maxWidth: 22, maxHeight: 22)
                    .frame(width: 26, height: 26)
                Text(provider.displayName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(provider.color)
                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(provider.color.opacity(0.6))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { onToggle() }

            // Family sections
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(provider.families) { family in
                        FamilySection(
                            family: family,
                            providerColor: provider.color,
                            currentModelId: currentModelId,
                            readOnly: readOnly,
                            isExpanded: expandedFamilies.contains(family.id),
                            expandedDetails: $expandedDetails,
                            onToggle: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    if expandedFamilies.contains(family.id) {
                                        expandedFamilies.remove(family.id)
                                    } else {
                                        expandedFamilies.insert(family.id)
                                    }
                                }
                            },
                            onSelect: onSelect
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .clipped()
        .sectionFill(provider.color, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Family Section

@available(iOS 26.0, *)
private struct FamilySection: View {
    let family: FamilyGroup
    let providerColor: Color
    let currentModelId: String
    let readOnly: Bool
    let isExpanded: Bool
    @Binding var expandedDetails: Set<String>
    let onToggle: () -> Void
    let onSelect: (ModelInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Family header
            HStack(spacing: 8) {
                Text(family.id)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(family.isRetired ? .tronTextMuted : .tronTextSecondary)

                // Model count badge
                Text("\(family.models.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(providerColor)

                if family.isRetired {
                    Text("Retired")
                        .font(TronTypography.sans(size: TronTypography.sizeXS))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Capsule())
                } else if family.isLatest {
                    Text("Latest")
                        .font(TronTypography.pillValue)
                        .foregroundStyle(providerColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(providerColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { onToggle() }

            // Models
            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(family.models) { model in
                        ModelCard(
                            model: model,
                            providerColor: providerColor,
                            isSelected: model.id == currentModelId,
                            readOnly: readOnly,
                            isDetailExpanded: expandedDetails.contains(model.id),
                            onToggleDetail: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    if expandedDetails.contains(model.id) {
                                        expandedDetails.remove(model.id)
                                    } else {
                                        expandedDetails.insert(model.id)
                                    }
                                }
                            },
                            onSelect: { onSelect(model) }
                        )
                        .id(model.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
        }
        .clipped()
        .sectionFill(providerColor, cornerRadius: 8, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Model Card

@available(iOS 26.0, *)
private struct ModelCard: View {
    let model: ModelInfo
    let providerColor: Color
    let isSelected: Bool
    let readOnly: Bool
    let isDetailExpanded: Bool
    let onToggleDetail: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row (always visible)
            HStack(spacing: 10) {
                // Selection circle
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        (readOnly || model.isDisabled)
                            ? .tronTextMuted.opacity(0.5)
                            : (isSelected ? providerColor : .tronTextMuted)
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeXL))

                VStack(alignment: .leading, spacing: 4) {
                    // Name row
                    HStack(spacing: 6) {
                        Text(model.formattedModelName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(model.isDisabled ? .tronTextMuted : .tronTextPrimary)

                        if model.recommended == true {
                            Text("Recommended")
                                .font(TronTypography.sans(size: TronTypography.sizeXS))
                                .foregroundStyle(providerColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(providerColor.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        if model.isRetiredModel {
                            Text("Retired")
                                .font(TronTypography.sans(size: TronTypography.sizeXS))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.15))
                                .clipShape(Capsule())
                        } else if model.isUnavailable {
                            Text("Unavailable")
                                .font(TronTypography.sans(size: TronTypography.sizeXS))
                                .foregroundStyle(.tronTextMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.tronTextMuted.opacity(0.15))
                                .clipShape(Capsule())
                        } else if model.isPreview {
                            Text("Preview")
                                .font(TronTypography.sans(size: TronTypography.sizeXS))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    // Stats row
                    HStack(spacing: 8) {
                        Text(model.formattedContextWindow)
                            .foregroundStyle(.tronTextSecondary)
                        if let maxOut = model.formattedMaxOutput {
                            Text(maxOut)
                                .foregroundStyle(.tronTextSecondary)
                        }
                        if let pricing = model.formattedPricing {
                            Text(pricing)
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .lineLimit(1)
                }

                Spacer()

                // Expand/collapse chevron
                Button {
                    onToggleDetail()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(isDetailExpanded ? -180 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { if !readOnly && !model.isDisabled { onSelect() } }

            // Expanded details
            if isDetailExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Unavailable reason (install instructions)
                    if let reason = model.unavailableReason, model.isUnavailable {
                        Text(reason)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronAmber)
                    }

                    // Description
                    if let desc = model.modelDescription, !desc.isEmpty {
                        Text(desc)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }

                    // Capability badges
                    HStack(spacing: 6) {
                        if model.supportsThinking {
                            capabilityBadge("Thinking", icon: "brain", color: providerColor)
                        }
                        if model.supportsReasoning == true {
                            capabilityBadge("Reasoning", icon: "sparkles", color: providerColor)
                        }
                        if model.supportsImages {
                            capabilityBadge("Vision", icon: "photo", color: providerColor)
                        }
                    }

                    // Retirement date
                    if let depDate = model.retirementDate {
                        Text("Retired \(depDate)")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.red.opacity(0.7))
                    }

                    // Release date
                    if let date = model.releaseDate {
                        Text("Released \(date)")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.leading, 38) // align with text after selection circle
            }
        }
        .clipped()
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? providerColor.opacity(0.2) : Color.clear)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(providerColor.opacity(0.5), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func capabilityBadge(_ label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(label)
        }
        .font(TronTypography.sans(size: TronTypography.sizeXS))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Reasoning Level Popover

@available(iOS 26.0, *)
private struct ReasoningLevelPopover: View {
    let levels: [String]
    let currentLevel: String
    let accentColor: Color
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(levels, id: \.self) { level in
                let isSelected = level == currentLevel
                Button {
                    onSelect(level)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Color.reasoningLevelIcon(level))
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .frame(width: 22)
                        Text(reasoningLabel(level))
                            .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(isSelected ? accentColor : .tronTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .contentShape(Capsule())
                    .background {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(
                                .regular.tint(isSelected ? accentColor.opacity(0.25) : Color.tronTextMuted.opacity(0.1)),
                                in: Capsule()
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 200)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .presentationBackground(.clear)
    }

    private func reasoningLabel(_ level: String) -> String {
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
}
