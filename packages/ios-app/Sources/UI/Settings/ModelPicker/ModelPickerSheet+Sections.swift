import SwiftUI

enum ModelPickerReasoningVisibility {
    static func showsReasoningControl(selectedModel: ModelInfo?, allowsSelection: Bool) -> Bool {
        allowsSelection
            && selectedModel?.supportsReasoning == true
            && !(selectedModel?.reasoningLevels ?? []).isEmpty
    }

    static func normalizedLevel(
        _ level: String?,
        for model: ModelInfo?
    ) -> String? {
        guard let model,
              model.supportsReasoning == true,
              let levels = model.reasoningLevels,
              !levels.isEmpty else { return nil }
        let uniqueLevels = levels.reduce(into: [String]()) { result, candidate in
            guard !candidate.isEmpty, !result.contains(candidate) else { return }
            result.append(candidate)
        }
        guard !uniqueLevels.isEmpty else { return nil }
        if let level, uniqueLevels.contains(level) { return level }
        if let defaultLevel = model.defaultReasoningLevel,
           uniqueLevels.contains(defaultLevel) {
            return defaultLevel
        }
        return uniqueLevels.first
    }
}

enum ModelPickerPresentation {
    static let primaryAccent: Color = .tronEmerald

    static func usesHighContrastNeutral(providerId: String, isDark: Bool) -> Bool {
        isDark && providerId == "openai-codex"
    }
}

// MARK: - Provider Section

struct ProviderSection: View {
    let provider: ProviderGroup
    let accentColor: Color
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
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: 22, maxHeight: 22)
                    .frame(width: 26, height: 26)
                Text(provider.displayName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accentColor)
                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(accentColor.opacity(0.75))
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
                            providerColor: accentColor,
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
        .sectionFill(accentColor, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Family Section

struct FamilySection: View {
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

struct ModelCard: View {
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

                    // Tool badges
                    HStack(spacing: 6) {
                        if model.supportsThinking {
                            toolBadge("Thinking", icon: "brain", color: providerColor)
                        }
                        if model.supportsReasoning == true {
                            toolBadge("Reasoning", icon: "sparkles", color: providerColor)
                        }
                        if model.supportsImages {
                            toolBadge("Vision", icon: "photo", color: providerColor)
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
    private func toolBadge(_ label: String, icon: String, color: Color) -> some View {
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
