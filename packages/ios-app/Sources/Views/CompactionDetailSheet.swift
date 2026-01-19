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
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }

    // MARK: - Token Visualization

    private var tokenVisualization: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Compression")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(spacing: 16) {
                // Before → After boxes
                HStack(spacing: 16) {
                    CompactionTokenBox(label: "Before", tokens: tokensBefore, color: .orange)
                    Image(systemName: "arrow.right")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.4))
                    CompactionTokenBox(label: "After", tokens: tokensAfter, color: .cyan)
                }

                // Stats row
                HStack(spacing: 16) {
                    CompactionStatBadge(label: "Saved", value: formatTokens(tokensSaved), color: .green)
                    CompactionStatBadge(label: "Reduction", value: "\(compressionPercent)%", color: .cyan)
                    CompactionStatBadge(label: reasonLabel, value: "", color: reasonColor)
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
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Copy button (only if summary exists)
                if let summary = summary {
                    Button {
                        UIPasteboard.general.string = summary
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.cyan.opacity(0.6))
                    }
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.cyan)

                    Text("Compaction Summary")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.cyan)

                    Spacer()
                }

                // Summary content
                if let summary = summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No summary available")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
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
        switch reason {
        case "pre_turn_guardrail": return "Auto"
        case "threshold_exceeded": return "Threshold"
        case "manual": return "Manual"
        default: return reason
        }
    }

    private var reasonColor: Color {
        switch reason {
        case "pre_turn_guardrail", "threshold_exceeded": return .orange
        case "manual": return .cyan
        default: return .gray
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000)
        }
        return "\(tokens)"
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
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Text(formatTokens(tokens))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
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

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000)
        }
        return "\(tokens)"
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
                .font(.system(size: 10, design: .monospaced))
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
