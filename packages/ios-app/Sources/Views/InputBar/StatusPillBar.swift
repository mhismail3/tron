import SwiftUI

// MARK: - Status Pills Column (iOS 26 Liquid Glass)

/// Vertical column of status pills: reasoning level, model picker, and token stats
/// Used as the right-side indicator area in InputBar
@available(iOS 26.0, *)
struct StatusPillsColumn: View {
    // Model info
    let modelName: String
    let cachedModels: [ModelInfo]
    let currentModelInfo: ModelInfo?

    // Context info
    let contextPercentage: Int
    let contextWindow: Int
    let lastTurnInputTokens: Int

    // Reasoning level
    @Binding var reasoningLevel: String

    // Animation state
    let hasAppeared: Bool

    // Namespaces for morph animations
    let reasoningPillNamespace: Namespace.ID

    // Actions
    var onContextTap: (() -> Void)?

    // Read-only mode (disables model and reasoning pickers)
    var readOnly: Bool = false

    // MARK: - Reasoning Level Helpers

    private func reasoningLevelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.capitalized
        }
    }

    private func reasoningLevelIcon(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "hare"
        case "medium": return "brain"
        case "high": return "brain.head.profile"
        case "xhigh": return "sparkles"
        case "max": return "flame"
        default: return "brain"
        }
    }

    /// Available reasoning levels from the current model, or default set
    private var availableReasoningLevels: [String] {
        currentModelInfo?.reasoningLevels ?? ["low", "medium", "high", "xhigh"]
    }

    private func reasoningLevelColor(_ level: String) -> Color {
        let levels = availableReasoningLevels
        let index = levels.firstIndex(of: level.lowercased()) ?? 0
        let progress = Double(index) / Double(max(levels.count - 1, 1))
        // Interpolate from #1F5E3F to #00A69B
        let lowR = 31.0 / 255.0, lowG = 94.0 / 255.0, lowB = 63.0 / 255.0
        let highR = 0.0 / 255.0, highG = 166.0 / 255.0, highB = 155.0 / 255.0
        return Color(
            red: lowR + (progress * (highR - lowR)),
            green: lowG + (progress * (highG - lowG)),
            blue: lowB + (progress * (highB - lowB))
        )
    }

    // MARK: - Context Helpers

    private var contextPercentageColor: Color {
        if contextPercentage >= 95 {
            return .red
        } else if contextPercentage >= 80 {
            return .orange
        }
        return .tronEmerald
    }

    private var tokensRemaining: Int {
        // Use last turn's input tokens as actual context size
        // (input tokens already includes system prompt + history, so it's the full context)
        return max(0, contextWindow - lastTurnInputTokens)
    }

    private var formattedTokensRemaining: String {
        let remaining = tokensRemaining
        if remaining >= 1_000_000 {
            return String(format: "%.1fM", Double(remaining) / 1_000_000)
        } else if remaining >= 1000 {
            return String(format: "%.0fk", Double(remaining) / 1000)
        }
        return "\(remaining)"
    }

    /// Whether reasoning pill should be visible
    private var showReasoningPill: Bool {
        currentModelInfo?.supportsReasoning == true
    }

    /// Whether model pill should be visible
    private var showModelPill: Bool {
        !modelName.isEmpty
    }

    // MARK: - Model Categorization

    /// Anthropic 4.5 models (latest)
    private var latestAnthropicModels: [ModelInfo] {
        cachedModels.filter { $0.isAnthropic && $0.isLatestGeneration }
            .uniqueByFormattedName()
            .sortedByTier()
    }

    /// Latest OpenAI Codex models (5.2 only)
    private var latestCodexModels: [ModelInfo] {
        cachedModels.filter { $0.isCodex && $0.id.lowercased().contains("5.2") }
    }

    /// Gemini 3 models (latest Google)
    private var gemini3Models: [ModelInfo] {
        cachedModels.filter { $0.isGemini && $0.isGemini3 }
            .sorted { geminiTierPriority($0) < geminiTierPriority($1) }
    }

    /// Legacy models: legacy Anthropic (non-4.5) + Codex 5.1 + Gemini 2.5
    private var legacyModels: [ModelInfo] {
        let legacyAnthropic = cachedModels.filter { $0.isAnthropic && !$0.isLatestGeneration }
            .uniqueByFormattedName()
            .sortedByTier()
        let legacyCodex = cachedModels.filter { $0.isCodex && !$0.id.lowercased().contains("5.2") }
        let legacyGemini = cachedModels.filter { $0.isGemini && !$0.isGemini3 }
            .sorted { geminiTierPriority($0) < geminiTierPriority($1) }
        return legacyAnthropic + legacyCodex + legacyGemini
    }

    private func geminiTierPriority(_ model: ModelInfo) -> Int {
        switch model.geminiTier {
        case "pro": return 0
        case "flash": return 1
        case "flash-lite": return 2
        default: return 3
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Reasoning level picker - morphs up from model pill area
            reasoningLevelMenu
                .scaleEffect(hasAppeared && showReasoningPill ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared && showReasoningPill ? 1 : 0)
                .allowsHitTesting(hasAppeared && showReasoningPill)

            // Model picker - morphs up from token pill area
            modelPickerMenu
                .scaleEffect(hasAppeared && showModelPill ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared && showModelPill ? 1 : 0)
                .allowsHitTesting(hasAppeared && showModelPill)

            // Token stats pill - morphs up from bottom (first to appear)
            tokenStatsPillWithChevrons
                .scaleEffect(hasAppeared ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared ? 1 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: hasAppeared)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showModelPill)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showReasoningPill)
    }

    // MARK: - Model Picker Menu

    private var modelPickerMenu: some View {
        // Separate visual (glass pill) from interaction (invisible Menu overlay)
        // This avoids the iOS 26 Menu + glassEffect transition bug
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(TronTypography.pill)
            Text(modelName.shortModelName)
                .font(TronTypography.pillValue)
            if !readOnly {
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.labelSM)
            }
        }
        .foregroundStyle(readOnly ? .tronEmerald.opacity(0.5) : .tronEmerald)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .capsule)
        .opacity(readOnly ? 0.5 : 1.0)
        .overlay {
            // Invisible Menu overlay handles interaction only
            Menu {
                // Latest Anthropic models (4.5)
                ForEach(latestAnthropicModels) { model in
                    Button {
                        NotificationCenter.default.post(name: .modelPickerAction, object: model)
                    } label: {
                        Label(model.formattedModelName, systemImage: "sparkles")
                    }
                }

                // Latest OpenAI Codex models (5.2)
                if !latestCodexModels.isEmpty {
                    Divider()
                    ForEach(latestCodexModels) { model in
                        Button {
                            NotificationCenter.default.post(name: .modelPickerAction, object: model)
                        } label: {
                            Label(model.formattedModelName, systemImage: "bolt")
                        }
                    }
                }

                // Gemini 3 models
                if !gemini3Models.isEmpty {
                    Divider()
                    ForEach(gemini3Models) { model in
                        Button {
                            NotificationCenter.default.post(name: .modelPickerAction, object: model)
                        } label: {
                            Label(model.formattedModelName, systemImage: "atom")
                        }
                    }
                }

                // Legacy models (legacy Anthropic + Codex 5.1 + Gemini 2.5)
                if !legacyModels.isEmpty {
                    Divider()
                    ForEach(legacyModels) { model in
                        Button {
                            NotificationCenter.default.post(name: .modelPickerAction, object: model)
                        } label: {
                            Label(model.formattedModelName, systemImage: "clock")
                        }
                    }
                }
            } label: {
                Color.clear
                    .contentShape(Capsule())
            }
            .disabled(readOnly)
        }
    }

    // MARK: - Reasoning Level Menu

    private var reasoningLevelMenu: some View {
        // Separate visual (glass pill) from interaction (invisible Menu overlay)
        // This avoids the iOS 26 Menu + glassEffect transition bug
        HStack(spacing: 4) {
            Image(systemName: reasoningLevelIcon(reasoningLevel))
                .font(TronTypography.pill)
            Text(reasoningLevelLabel(reasoningLevel))
                .font(TronTypography.pillValue)
            if !readOnly {
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.labelSM)
            }
        }
        .foregroundStyle(readOnly ? reasoningLevelColor(reasoningLevel).opacity(0.5) : reasoningLevelColor(reasoningLevel))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .capsule)
        .opacity(readOnly ? 0.5 : 1.0)
        .overlay {
            // Invisible Menu overlay handles interaction only
            Menu {
                ForEach(availableReasoningLevels, id: \.self) { level in
                    Button {
                        NotificationCenter.default.post(name: .reasoningLevelAction, object: level)
                    } label: {
                        Label(reasoningLevelLabel(level), systemImage: reasoningLevelIcon(level))
                    }
                }
            } label: {
                Color.clear
                    .contentShape(Capsule())
            }
            .disabled(readOnly)
        }
        .matchedGeometryEffect(id: "reasoningPillMorph", in: reasoningPillNamespace)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
            removal: .scale(scale: 0.8).combined(with: .opacity)
        ))
    }

    // MARK: - Token Stats Pill

    private var tokenStatsPillWithChevrons: some View {
        Button {
            onContextTap?()
        } label: {
            HStack(spacing: 8) {
                // Context usage bar - use overlay + clipShape to prevent overflow
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 40, height: 6)
                    .overlay(alignment: .leading) {
                        // Fill rectangle that gets clipped by parent Capsule shape
                        Rectangle()
                            .fill(contextPercentageColor)
                            .frame(width: 40 * min(CGFloat(contextPercentage) / 100.0, 1.0))
                    }
                    .clipShape(Capsule())

                // Tokens remaining + Chevrons (spacing: 4 to match model pill)
                HStack(spacing: 4) {
                    Text("\(formattedTokensRemaining) left")
                        .foregroundStyle(contextPercentageColor)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(TronTypography.labelSM)
                        .foregroundStyle(contextPercentageColor)
                }
            }
            .font(TronTypography.pillValue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .capsule)
    }
}

// MARK: - Token Stats Pill (Standalone)

/// Standalone token stats pill without chevrons (for legacy/fallback use)
@available(iOS 26.0, *)
struct TokenStatsPill: View {
    let contextPercentage: Int
    let contextWindow: Int
    let lastTurnInputTokens: Int
    var onContextTap: (() -> Void)?

    private var contextPercentageColor: Color {
        if contextPercentage >= 95 {
            return .red
        } else if contextPercentage >= 80 {
            return .orange
        }
        return .tronEmerald
    }

    private var tokensRemaining: Int {
        return max(0, contextWindow - lastTurnInputTokens)
    }

    private var formattedTokensRemaining: String {
        let remaining = tokensRemaining
        if remaining >= 1_000_000 {
            return String(format: "%.1fM", Double(remaining) / 1_000_000)
        } else if remaining >= 1000 {
            return String(format: "%.0fk", Double(remaining) / 1000)
        }
        return "\(remaining)"
    }

    var body: some View {
        Button {
            onContextTap?()
        } label: {
            HStack(spacing: 8) {
                // Context usage bar
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 40, height: 6)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(contextPercentageColor)
                            .frame(width: 40 * min(CGFloat(contextPercentage) / 100.0, 1.0))
                    }
                    .clipShape(Capsule())

                // Tokens remaining
                Text("\(formattedTokensRemaining) left")
                    .foregroundStyle(contextPercentageColor)
            }
            .font(TronTypography.pillValue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .capsule)
    }
}
