import SwiftUI

// MARK: - TaskManager Chip

/// Compact chip for TaskManager tool calls
/// Shows "Task Manager" label in bold + action summary
/// Follows CommandToolChip pattern: bold name, lighter summary, chevron
struct TaskManagerChip: View {
    let data: TaskManagerChipData
    let onTap: () -> Void

    var body: some View {
        Group {
            if data.status == .completed {
                Button(action: onTap) {
                    chipContent
                }
                .buttonStyle(.plain)
            } else {
                chipContent
            }
        }
        .chipStyle(.tronSlate)
        .chipAccessibility(tool: "Task Manager", status: data.status == .completed ? "Completed" : "Running", summary: data.chipSummary)
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            statusIcon

            Text("Task Manager")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronSlate)

            Text(data.chipSummary)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronSlate.opacity(0.7))
                .lineLimit(1)

            if let duration = data.formattedDuration {
                Text(duration)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronSlate.opacity(0.5))
            }

            if data.status == .completed {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronSlate.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: TronTypography.sizeBodySM, height: TronTypography.sizeBodySM)
                .tint(.tronSlate)
        case .completed:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSlate)
        }
    }
}
