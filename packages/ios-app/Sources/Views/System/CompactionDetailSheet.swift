import SwiftUI

/// Detail sheet shown when tapping the compaction notification pill.
/// Displays Before → After token visualization and the compaction summary.
@available(iOS 26.0, *)
struct CompactionDetailSheet: View {
    let tokensBefore: Int
    let tokensAfter: Int
    let reason: String
    let summary: String?
    @Environment(\.dismiss) private var dismiss

    private var tokensSaved: Int { tokensBefore - tokensAfter }

    private var compressionPercent: Int {
        guard tokensBefore > 0 else { return 0 }
        return Int((Double(tokensSaved) / Double(tokensBefore)) * 100)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // Before → After visualization
                    tokenVisualization
                        .padding(.horizontal)

                    // Summary section
                    summarySection
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Context Compacted")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(.cyan)
    }

    // MARK: - Token Visualization

    private var tokenVisualization: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Compression")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            // Card content
            VStack(spacing: 16) {
                // Before → After boxes
                HStack(spacing: 16) {
                    CompactionTokenBox(label: "Before", tokens: tokensBefore, color: .cyan)
                    Image(systemName: "arrow.right")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronTextMuted)
                    CompactionTokenBox(label: "After", tokens: tokensAfter, color: .cyan)
                }

                // Stats row - all badges use mint for subtle distinction from cyan boxes
                HStack(spacing: 16) {
                    CompactionStatBadge(label: "Saved", value: TokenFormatter.format(tokensSaved), color: .mint)
                    CompactionStatBadge(label: "Reduction", value: "\(compressionPercent)%", color: .mint)
                    CompactionStatBadge(label: reasonLabel, value: "", color: .mint)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.cyan.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("Summary")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                // Copy button (only if summary exists)
                if let summary = summary {
                    Button {
                        UIPasteboard.general.string = summary
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.cyan.opacity(0.6))
                    }
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.cyan)

                    Text("Compaction Summary")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.cyan)

                    Spacer()
                }

                // Summary content
                if let summary = summary, !summary.isEmpty {
                    Text(summary)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No summary available")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextDisabled)
                        .italic()
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.cyan.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Helpers

    private var reasonLabel: String {
        CompactionReason(rawValue: reason)?.detailDisplayText ?? reason
    }
}

// MARK: - Helper Views

@available(iOS 26.0, *)
private struct CompactionTokenBox: View {
    let label: String
    let tokens: Int
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronTextMuted)
            Text(TokenFormatter.format(tokens))
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.15)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

@available(iOS 26.0, *)
private struct CompactionStatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
            if !value.isEmpty {
                Text(value)
                    .font(TronTypography.pillValue)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.2)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
