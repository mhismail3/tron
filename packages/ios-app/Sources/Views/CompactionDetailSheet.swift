import SwiftUI

/// Detail sheet shown when tapping the compaction notification pill.
/// Displays Before → After token visualization and compression stats.
@available(iOS 26.0, *)
struct CompactionDetailSheet: View {
    let tokensBefore: Int
    let tokensAfter: Int
    let reason: String
    @Environment(\.dismiss) private var dismiss

    private var tokensSaved: Int { tokensBefore - tokensAfter }

    private var compressionPercent: Int {
        guard tokensBefore > 0 else { return 0 }
        return Int((Double(tokensSaved) / Double(tokensBefore)) * 100)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Before → After visualization
                HStack(spacing: 20) {
                    CompactionTokenBox(label: "Before", tokens: tokensBefore, color: .orange)
                    Image(systemName: "arrow.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    CompactionTokenBox(label: "After", tokens: tokensAfter, color: .cyan)
                }
                .padding(.top, 20)

                // Stats
                VStack(spacing: 12) {
                    CompactionStatRow(label: "Tokens saved", value: formatTokens(tokensSaved))
                    CompactionStatRow(label: "Compression", value: "\(compressionPercent)%")
                    CompactionStatRow(label: "Reason", value: reasonDisplay)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Spacer()
            }
            .padding()
            .navigationTitle("Context Compacted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var reasonDisplay: String {
        switch reason {
        case "pre_turn_guardrail": return "Auto (context limit)"
        case "threshold_exceeded": return "Auto (threshold)"
        case "manual": return "Manual"
        default: return reason
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

private struct CompactionTokenBox: View {
    let label: String
    let tokens: Int
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatTokens(tokens))
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 100)
        .padding()
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000)
        }
        return "\(tokens)"
    }
}

private struct CompactionStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
