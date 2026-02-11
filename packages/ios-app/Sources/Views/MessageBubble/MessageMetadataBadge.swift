import SwiftUI

// MARK: - Token Badge (Terminal-style)

struct TokenBadge: View {
    let record: TokenRecord

    var body: some View {
        HStack(spacing: 8) {
            // Input/Output tokens (using computed newInputTokens for delta display)
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(TronTypography.labelSM)
                Text(record.formattedNewInput)
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(TronTypography.labelSM)
                Text(record.formattedOutput)
            }

            // Cache section (if any cache activity)
            if record.hasCacheActivity {
                Text("\u{2022}")
                    .foregroundStyle(.tronTextMuted)

                // Cache read
                if let cacheRead = record.formattedCacheRead {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(TronTypography.labelSM)
                        Text(cacheRead)
                    }
                    .foregroundStyle(.tronAmberLight)
                }

                // Cache write
                if let cacheWrite = record.formattedCacheWrite {
                    HStack(spacing: 2) {
                        Image(systemName: "pencil")
                            .font(TronTypography.labelSM)
                        Text(cacheWrite)
                    }
                    .foregroundStyle(.tronAmber)
                }
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
    let tokenRecord: TokenRecord?
    let model: String?
    let latency: String?
    let hasThinking: Bool?

    /// Check if we need a separator before additional metadata
    private var needsSeparator: Bool {
        tokenRecord != nil && (model != nil || latency != nil || hasThinking == true)
    }

    /// Check if we need a separator between model and latency
    private var needsModelLatencySeparator: Bool {
        model != nil && latency != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            // Token record
            if let record = tokenRecord {
                TokenBadge(record: record)
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
