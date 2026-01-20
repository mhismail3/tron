import SwiftUI

// MARK: - Token Badge (Terminal-style)

struct TokenBadge: View {
    let usage: TokenUsage

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(TronTypography.labelSM)
                Text(usage.formattedInput)
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(TronTypography.labelSM)
                Text(usage.formattedOutput)
            }
        }
        .font(TronTypography.codeSM)
        .foregroundStyle(.tronTextMuted)
    }
}

// MARK: - Message Metadata Badge (Enriched Phase 1)

/// Displays comprehensive metadata beneath assistant messages:
/// Token usage, model name, latency, and thinking indicator
struct MessageMetadataBadge: View {
    let usage: TokenUsage?
    /// Incremental tokens (delta from previous turn) for display - preferred over raw usage
    let incrementalUsage: TokenUsage?
    let model: String?
    let latency: String?
    let hasThinking: Bool?

    /// The token usage to display - prefer incremental if available
    private var displayUsage: TokenUsage? {
        incrementalUsage ?? usage
    }

    /// Check if we need a separator before additional metadata
    private var needsSeparator: Bool {
        displayUsage != nil && (model != nil || latency != nil || hasThinking == true)
    }

    /// Check if we need a separator between model and latency
    private var needsModelLatencySeparator: Bool {
        model != nil && latency != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            // Token usage - show incremental if available, otherwise full
            if let usage = displayUsage {
                TokenBadge(usage: usage)
            }

            // Separator after tokens
            if needsSeparator {
                Text("\u{2022}")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }

            // Model name pill
            if let model = model {
                Text(model)
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronTextMuted)
            }

            // Separator between model and latency
            if needsModelLatencySeparator {
                Text("\u{2022}")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }

            // Latency pill
            if let latency = latency {
                Text(latency)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }

            // Thinking indicator (text, not emoji)
            if hasThinking == true {
                Text("Thinking")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronAmber)
            }
        }
    }
}
