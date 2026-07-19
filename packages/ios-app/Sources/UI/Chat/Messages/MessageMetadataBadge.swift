import SwiftUI

// MARK: - Token Badge

private struct TokenBadge: View {
    let record: TokenRecord

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(TronTypography.labelSM)
                Text(record.formattedInput)
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(TronTypography.labelSM)
                Text(record.formattedOutput)
            }

            if let cache = record.formattedCache {
                HStack(spacing: 2) {
                    Image(systemName: "externaldrive")
                        .font(TronTypography.labelSM)
                    Text(cache)
                }
            }

            if let cost = record.pricing.cost {
                Text(formatCost(cost.totalCost))
            } else if !record.pricing.available {
                Text("cost unavailable")
            }
        }
        .font(TronTypography.codeSM)
        .foregroundStyle(.tronTextMuted)
    }
}

// MARK: - Final Assistant Response Metadata

/// Displays metadata only after a server-identified final assistant response.
struct MessageMetadataBadge: View {
    let metadata: FinalAssistantResponseMetadata

    var body: some View {
        HStack(spacing: 8) {
            if let record = metadata.tokenRecord {
                TokenBadge(record: record)
            }

            if metadata.tokenRecord != nil && (metadata.model != nil || metadata.latency != nil) {
                Text("\u{2022}")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }

            if let model = metadata.model {
                Text(model)
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronTextMuted)
            }

            if metadata.model != nil && metadata.latency != nil {
                Text("\u{2022}")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }

            if let latency = metadata.latency {
                Text(latency)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }
        }
    }
}
