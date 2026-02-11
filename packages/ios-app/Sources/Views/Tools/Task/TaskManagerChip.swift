import SwiftUI

// MARK: - TaskManager Chip (iOS 26)

/// Compact chip for TaskManager tool calls
/// Shows spinner + action text while running,
/// then result summary when complete
/// Tappable (when completed) to open TaskDetailSheet
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

            Text(statusText)
                .font(TronTypography.filePath)
                .foregroundStyle(.tronSlate)
                .lineLimit(1)

            if data.status == .completed {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronSlate.opacity(0.6))
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
                .scaleEffect(0.7)
                .tint(.tronSlate)
        case .completed:
            Image(systemName: "checklist")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSlate)
        }
    }

    private var statusText: String {
        switch data.status {
        case .running:
            return runningText
        case .completed:
            if let summary = data.resultSummary {
                return summary
            }
            return completedText
        }
    }

    private var runningText: String {
        switch data.action {
        case "create": return "Creating task..."
        case "update": return "Updating task..."
        case "delete": return "Deleting task..."
        case "list": return "Listing tasks..."
        case "search": return "Searching tasks..."
        case "get": return "Getting task..."
        case "create_project": return "Creating project..."
        case "update_project": return "Updating project..."
        case "list_projects": return "Listing projects..."
        default: return "Managing tasks..."
        }
    }

    private var completedText: String {
        switch data.action {
        case "create": return "Task created"
        case "update": return "Task updated"
        case "delete": return "Task deleted"
        case "list": return "Tasks listed"
        default: return "Tasks updated"
        }
    }
}

// MARK: - TaskManager Chip Fallback (iOS < 26)

/// Fallback chip without glass effect for older iOS versions
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

            Text(statusText)
                .font(TronTypography.filePath)
                .foregroundStyle(.tronSlate)
                .lineLimit(1)

            if data.status == .completed {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronSlate.opacity(0.6))
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
                .scaleEffect(0.7)
                .tint(.tronSlate)
        case .completed:
            Image(systemName: "checklist")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSlate)
        }
    }

    private var statusText: String {
        switch data.status {
        case .running:
            switch data.action {
            case "create": return "Creating task..."
            case "update": return "Updating task..."
            case "delete": return "Deleting task..."
            case "list": return "Listing tasks..."
            default: return "Managing tasks..."
            }
        case .completed:
            if let summary = data.resultSummary {
                return summary
            }
            switch data.action {
            case "create": return "Task created"
            case "update": return "Task updated"
            case "delete": return "Task deleted"
            case "list": return "Tasks listed"
            default: return "Tasks updated"
            }
        }
    }
}
