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
        case "xhigh": return "Max"
        default: return level.capitalized
        }
    }

    /// Description for each reasoning level
    private func levelDescription(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Fastest responses, minimal reasoning"
        case "medium": return "Balanced speed and depth"
        case "high": return "Deep reasoning for complex tasks"
        case "xhigh": return "Maximum reasoning power"
        default: return ""
        }
    }

    /// Icon for each level
    private func levelIcon(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "hare"
        case "medium": return "brain"
        case "high": return "brain.head.profile"
        case "xhigh": return "sparkles"
        default: return "brain"
        }
    }

    var body: some View {
        if model.supportsReasoning == true {
            Menu {
                ForEach(levels, id: \.self) { level in
                    Button {
                        selectedLevel = level
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(levelLabel(level))
                                    if !levelDescription(level).isEmpty {
                                        Text(levelDescription(level))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: levelIcon(level))
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
                ReasoningLevelPillLabel(level: selectedLevel, labelFunc: levelLabel)
            }
            .glassEffect(.regular.tint(Color.tronAmber.opacity(0.3)).interactive(), in: .capsule)
        }
    }
}

/// Compact pill label showing current reasoning level
@available(iOS 26.0, *)
struct ReasoningLevelPillLabel: View {
    let level: String
    let labelFunc: (String) -> String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .medium))
            Text(labelFunc(level))
                .font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
                    .font(.system(size: 14, weight: .medium))
            }
            .disabled(currentIndex == 0)

            // Current level indicator
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text(level.prefix(1).uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .frame(minWidth: 32)

            // Increase button
            Button {
                if currentIndex < levels.count - 1 {
                    level = levels[currentIndex + 1]
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .disabled(currentIndex == levels.count - 1)
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    VStack(spacing: 20) {
        // Mock Codex model
        let mockModel = ModelInfo(
            id: "gpt-5.2-codex",
            name: "Codex 5.2",
            provider: "openai-codex",
            contextWindow: 400000,
            maxOutputTokens: 128000,
            supportsThinking: false,
            supportsImages: true,
            tier: "flagship",
            isLegacy: false,
            supportsReasoning: true,
            reasoningLevels: ["low", "medium", "high", "xhigh"],
            defaultReasoningLevel: "medium"
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
        .background(Color.black.opacity(0.3))
        .clipShape(Capsule())
    }
    .padding()
    .preferredColorScheme(.dark)
}
