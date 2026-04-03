import SwiftUI

// MARK: - Reasoning Level Picker

/// A picker for selecting reasoning effort level for OpenAI Codex models.
/// Shows as a compact pill that expands to a menu with level options.
@available(iOS 26.0, *)
struct ReasoningLevelPicker: View {
    let model: ModelInfo
    @Binding var selectedLevel: String

    /// Available levels from the model, or default set
    private var levels: [String] {
        model.reasoningLevels ?? ["low", "medium", "high", "xhigh"]
    }

    /// Human-readable labels for each level
    private func levelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.capitalized
        }
    }

    /// Description for each reasoning level
    private func levelDescription(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Fastest responses, minimal reasoning"
        case "medium": return "Balanced speed and depth"
        case "high": return "Deep reasoning for complex tasks"
        case "xhigh": return "Extra high reasoning power"
        case "max": return "Maximum reasoning power"
        default: return ""
        }
    }

    var body: some View {
        if model.supportsReasoning == true {
            Menu {
                ForEach(levels, id: \.self) { level in
                    Button {
                        // iOS 26 Menu workaround: Post notification instead of direct state mutation
                        NotificationCenter.default.post(name: .reasoningLevelAction, object: level)
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(levelLabel(level))
                                    if !levelDescription(level).isEmpty {
                                        Text(levelDescription(level))
                                            .font(TronTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: Color.reasoningLevelIcon(level))
                                    .foregroundStyle(Color.reasoningLevel(level, levels: levels))
                            }

                            Spacer()

                            if level == selectedLevel {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tronEmerald)
                            }
                        }
                    }
                }
            } label: {
                ReasoningLevelPillLabel(
                    level: selectedLevel,
                    labelFunc: levelLabel,
                    levels: levels,
                    includeGlassEffect: true
                )
            }
        }
    }
}

/// Compact pill label showing current reasoning level
@available(iOS 26.0, *)
struct ReasoningLevelPillLabel: View {
    let level: String
    let labelFunc: (String) -> String
    var levels: [String] = ["low", "medium", "high", "xhigh"]
    /// When true, applies glassEffect directly to the label (for use inside Menu labels)
    var includeGlassEffect: Bool = false

    private var levelColor: Color {
        Color.reasoningLevel(level, levels: levels)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Color.reasoningLevelIcon(level))
                .font(TronTypography.pill)
            Text(labelFunc(level))
                .font(TronTypography.codeSM)
            Image(systemName: "chevron.up.chevron.down")
                .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
        }
        .foregroundStyle(levelColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if includeGlassEffect {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(levelColor.opacity(0.35)), in: .capsule)
            }
        }
        .contentShape(Capsule())
    }
}

// MARK: - Inline Reasoning Level Control

/// Simpler inline control for reasoning level (for use in toolbars/compact spaces)
@available(iOS 26.0, *)
struct InlineReasoningControl: View {
    @Binding var level: String
    let levels: [String]

    private var currentIndex: Int {
        levels.firstIndex(of: level) ?? 1
    }

    var body: some View {
        HStack(spacing: 8) {
            // Decrease button
            Button {
                if currentIndex > 0 {
                    level = levels[currentIndex - 1]
                }
            } label: {
                Image(systemName: "minus.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            }
            .disabled(currentIndex == 0)

            // Current level indicator
            HStack(spacing: 4) {
                Image(systemName: Color.reasoningLevelIcon(level))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                Text(level.prefix(1).uppercased())
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
            }
            .frame(minWidth: 32)
            .foregroundStyle(Color.reasoningLevel(level, levels: levels))

            // Increase button
            Button {
                if currentIndex < levels.count - 1 {
                    level = levels[currentIndex + 1]
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            }
            .disabled(currentIndex == levels.count - 1)
        }
        .foregroundStyle(.tronTextSecondary)
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview {
    VStack(spacing: 20) {
        // Mock Codex model
        let mockModel = ModelInfo(
            id: "gpt-5.3-codex",
            name: "Codex 5.3",
            provider: "openai-codex",
            contextWindow: 400000,
            maxOutputTokens: 128000,
            supportsThinking: false,
            supportsImages: true,
            tier: "flagship",
            isLegacy: false,
            supportsReasoning: true,
            reasoningLevels: ["low", "medium", "high", "xhigh"],
            defaultReasoningLevel: "medium",
            thinkingLevel: nil,
            supportedThinkingLevels: nil
        )

        ReasoningLevelPicker(
            model: mockModel,
            selectedLevel: .constant("medium")
        )

        // Inline control
        InlineReasoningControl(
            level: .constant("medium"),
            levels: ["low", "medium", "high", "xhigh"]
        )
        .padding()
        .background(Color.tronSurfaceElevated)
        .clipShape(Capsule())

        // Show all level colors
        HStack(spacing: 12) {
            ForEach(["low", "medium", "high", "xhigh"], id: \.self) { level in
                VStack {
                    Circle()
                        .fill(Color.reasoningLevel(level))
                        .frame(width: 24, height: 24)
                    Text(level)
                        .font(TronTypography.caption2)
                }
            }
        }
    }
    .padding()
}
#endif
