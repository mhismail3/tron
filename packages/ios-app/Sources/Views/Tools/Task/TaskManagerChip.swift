import SwiftUI

// MARK: - TaskManager Chip (iOS 26)

/// Compact chip for TaskManager tool calls
/// Shows "Task Manager" label in bold + action summary
/// Follows CommandToolChip pattern: bold name, lighter summary, chevron
@available(iOS 26.0, *)
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
        .glassEffect(
            .regular.tint(Color.tronSlate.opacity(0.35)).interactive(),
            in: .capsule
        )
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
            Image(systemName: "checklist")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSlate)
        }
    }
}

// MARK: - TaskManager Chip Fallback (iOS < 26)

struct TaskManagerChipFallback: View {
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
        .chipFill(.tronSlate)
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
            Image(systemName: "checklist")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSlate)
        }
    }
}
