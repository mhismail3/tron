import SwiftUI
import UIKit

/// Detail sheet shown when tapping a subagent chip.
/// Displays task info, status, duration, turn count, and full output.
@available(iOS 26.0, *)
struct SubagentDetailSheet: View {
    let data: SubagentToolData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // Header card
                    headerCard
                        .padding(.horizontal)

                    // Task section
                    taskSection
                        .padding(.horizontal)

                    // Output section (when completed)
                    if data.status == .completed, let summary = data.resultSummary {
                        outputSection(summary: summary, fullOutput: data.fullOutput)
                            .padding(.horizontal)
                    }

                    // Error section (when failed)
                    if data.status == .failed, let error = data.error {
                        errorSection(error: error)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(titleText)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(titleColor)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(titleColor)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Status")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(spacing: 16) {
                // Status badge
                HStack {
                    statusIcon
                    Text(statusText)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(statusColor)
                    Spacer()
                }

                // Stats row
                HStack(spacing: 12) {
                    SubagentStatBadge(label: "Turns", value: "\(data.currentTurn)", color: titleColor)

                    if let duration = data.formattedDuration {
                        SubagentStatBadge(label: "Duration", value: duration, color: titleColor)
                    }

                    if let model = data.model {
                        SubagentStatBadge(label: "Model", value: formatModelName(model), color: titleColor)
                    }
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(titleColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Task Section

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Task")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(alignment: .leading, spacing: 8) {
                Text(data.task)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(titleColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Output Section

    private func outputSection(summary: String, fullOutput: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("Output")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Copy button
                if let output = fullOutput {
                    Button {
                        UIPasteboard.general.string = output
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(titleColor.opacity(0.6))
                    }
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 12) {
                // Summary
                HStack {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronSuccess)
                    Text("Summary")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronSuccess)
                    Spacer()
                }

                Text(summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Full output (if available and different from summary)
                if let output = fullOutput, output != summary, !output.isEmpty {
                    Divider()
                        .background(.white.opacity(0.2))

                    Text("Full Output")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronSuccess.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Error Section

    private func errorSection(error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Error")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronError)
                    Text("Failed")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronError)
                    Spacer()
                }

                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronError.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .spawning:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
                .tint(.tronEmerald)
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
                .tint(.tronEmerald)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .spawning: return "Spawning..."
        case .running: return "Running (turn \(data.currentTurn))"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .spawning, .running: return .tronEmerald
        case .completed: return .tronSuccess
        case .failed: return .tronError
        }
    }

    private var titleText: String {
        switch data.status {
        case .spawning: return "Sub-Agent Spawning"
        case .running: return "Sub-Agent Running"
        case .completed: return "Sub-Agent Completed"
        case .failed: return "Sub-Agent Failed"
        }
    }

    private var titleColor: Color {
        switch data.status {
        case .spawning, .running: return .tronEmerald
        case .completed: return .tronSuccess
        case .failed: return .tronError
        }
    }

    private func formatModelName(_ model: String) -> String {
        // Extract the short name from full model ID
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model.count > 10 ? String(model.prefix(10)) + "..." : model
    }
}

// MARK: - Helper Views

@available(iOS 26.0, *)
private struct SubagentStatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
