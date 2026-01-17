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

    // MARK: - Model Categorization

    /// Anthropic 4.5 models (latest) - sorted: Haiku (top) → Sonnet → Opus (bottom, closest to thumb)
    private var latestAnthropicModels: [ModelInfo] {
        cachedModels.filter { $0.isAnthropic && $0.is45Model }
            .sorted { tierPriority($0) > tierPriority($1) }
    }

    /// OpenAI Codex models - sorted: 5.1 (top) → 5.2 (bottom, closest to thumb)
    private var codexModels: [ModelInfo] {
        cachedModels.filter { $0.provider.lowercased() == "openai-codex" }
            .sorted { codexVersionPriority($0) < codexVersionPriority($1) }
    }

    /// Legacy Anthropic models (non-4.5) - sorted: Sonnet (top) → Opus (bottom)
    private var legacyModels: [ModelInfo] {
        cachedModels.filter { $0.isAnthropic && !$0.is45Model }
            .sorted { tierPriority($0) > tierPriority($1) }
    }

    private func tierPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("opus") { return 0 }
        if id.contains("sonnet") { return 1 }
        if id.contains("haiku") { return 2 }
        return 3
    }

    private func codexVersionPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("5.2") { return 52 }
        if id.contains("5.1") { return 51 }
        if id.contains("5.0") || id.contains("-5-") { return 50 }
        return 0
    }

    // MARK: - Reasoning Level Helpers

    private func reasoningLevelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Max"
        default: return level.capitalized
        }
    }

    private func reasoningLevelIcon(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "hare"
        case "medium": return "brain"
        case "high": return "brain.head.profile"
        case "xhigh": return "sparkles"
        default: return "brain"
        }
    }

    private func reasoningLevelColor(_ level: String) -> Color {
        let levels = ["low", "medium", "high", "xhigh"]
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
        Menu {
            // Anthropic 4.5 models at top (closest to thumb when menu opens upward)
            ForEach(latestAnthropicModels) { model in
                Button { NotificationCenter.default.post(name: .modelPickerAction, object: model) } label: {
                    Label(model.formattedModelName, systemImage: "sparkles")
                }
            }
            Divider()

            // OpenAI Codex models in middle
            if !codexModels.isEmpty {
                ForEach(codexModels) { model in
                    Button { NotificationCenter.default.post(name: .modelPickerAction, object: model) } label: {
                        Label(model.formattedModelName, systemImage: "bolt")
                    }
                }
                Divider()
            }

            // Legacy models at bottom (furthest from thumb)
            if !legacyModels.isEmpty {
                ForEach(legacyModels) { model in
                    Button { NotificationCenter.default.post(name: .modelPickerAction, object: model) } label: {
                        Label(model.formattedModelName, systemImage: "clock")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .medium))
                Text(modelName.shortModelName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
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

    // MARK: - Reasoning Level Menu

    private var reasoningLevelMenu: some View {
        Menu {
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "low") } label: {
                Label("Low", systemImage: "hare")
            }
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "medium") } label: {
                Label("Medium", systemImage: "brain")
            }
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "high") } label: {
                Label("High", systemImage: "brain.head.profile")
            }
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "xhigh") } label: {
                Label("Max", systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: reasoningLevelIcon(reasoningLevel))
                    .font(.system(size: 9, weight: .medium))
                Text(reasoningLevelLabel(reasoningLevel))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(reasoningLevelColor(reasoningLevel))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: .capsule)
            }
            .contentShape(Capsule())
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
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(contextPercentageColor)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
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
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .capsule)
    }
}
