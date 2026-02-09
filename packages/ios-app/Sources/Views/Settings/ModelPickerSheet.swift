import SwiftUI

// MARK: - Model Picker Sheet

/// Rich bottom sheet for model selection with Provider > Family > Model hierarchy.
/// Follows ContextAuditView patterns: NavigationStack, ScrollView, collapsible sections.
@available(iOS 26.0, *)
struct ModelPickerSheet: View {
    let models: [ModelInfo]
    let currentModelId: String
    let onSelect: (ModelInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var expandedFamilies: Set<String> = []
    @State private var expandedDetails: Set<String> = []

    private var providerGroups: [ProviderGroup] {
        ModelFilteringService.organizeByProviderFamily(models)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(providerGroups) { provider in
                        ProviderSection(
                            provider: provider,
                            currentModelId: currentModelId,
                            expandedFamilies: $expandedFamilies,
                            expandedDetails: $expandedDetails,
                            onSelect: { model in
                                onSelect(model)
                                dismiss()
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Models")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            // Initialize expanded families to latest ones
            for provider in providerGroups {
                for family in provider.families where family.isLatest {
                    expandedFamilies.insert(family.id)
                }
            }
        }
    }
}

// MARK: - Provider Section

@available(iOS 26.0, *)
private struct ProviderSection: View {
    let provider: ProviderGroup
    let currentModelId: String
    @Binding var expandedFamilies: Set<String>
    @Binding var expandedDetails: Set<String>
    let onSelect: (ModelInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Provider header
            HStack(spacing: 8) {
                Image(provider.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(provider.color)
                    .frame(width: 18, height: 18)
                Text(provider.displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(provider.color)
                Spacer()
            }
            .padding(12)

            // Family sections
            VStack(spacing: 8) {
                ForEach(provider.families) { family in
                    FamilySection(
                        family: family,
                        providerColor: provider.color,
                        currentModelId: currentModelId,
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
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(provider.color.opacity(0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Family Section

@available(iOS 26.0, *)
private struct FamilySection: View {
    let family: FamilyGroup
    let providerColor: Color
    let currentModelId: String
    let isExpanded: Bool
    @Binding var expandedDetails: Set<String>
    let onToggle: () -> Void
    let onSelect: (ModelInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Family header
            HStack(spacing: 8) {
                Text(family.id)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                // Model count badge
                Text("\(family.models.count)")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronTextPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(providerColor.opacity(0.5))
                    .clipShape(Capsule())

                if family.isLatest {
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
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
        }
        .clipped()
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.tronSurfaceElevated)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Model Card

@available(iOS 26.0, *)
private struct ModelCard: View {
    let model: ModelInfo
    let providerColor: Color
    let isSelected: Bool
    let isDetailExpanded: Bool
    let onToggleDetail: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row (always visible)
            HStack(spacing: 10) {
                // Selection circle
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? providerColor : .tronTextMuted)
                    .font(TronTypography.sans(size: TronTypography.sizeXL))

                VStack(alignment: .leading, spacing: 4) {
                    // Name row
                    HStack(spacing: 6) {
                        Text(model.formattedModelName)
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)

                        if model.recommended == true {
                            Text("Recommended")
                                .font(TronTypography.mono(size: TronTypography.sizeXS))
                                .foregroundStyle(providerColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(providerColor.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        if model.isPreview {
                            Text("Preview")
                                .font(TronTypography.mono(size: TronTypography.sizeXS))
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
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
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
            .onTapGesture { onSelect() }

            // Expanded details
            if isDetailExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Description
                    if let desc = model.modelDescription, !desc.isEmpty {
                        Text(desc)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }

                    // Capability badges
                    HStack(spacing: 6) {
                        if model.supportsThinking == true {
                            capabilityBadge("Thinking", icon: "brain", color: providerColor)
                        }
                        if model.supportsReasoning == true {
                            capabilityBadge("Reasoning", icon: "sparkles", color: providerColor)
                        }
                        if model.supportsImages == true {
                            capabilityBadge("Vision", icon: "photo", color: providerColor)
                        }
                    }

                    // Release date
                    if let date = model.releaseDate {
                        Text("Released \(date)")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
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
        .font(TronTypography.mono(size: TronTypography.sizeXS))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}
