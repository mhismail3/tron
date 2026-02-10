import SwiftUI

// MARK: - TodoWrite Chip (iOS 26)

/// Compact chip for TodoWrite tool calls
/// Shows spinner + "Updating Tasks..." while running,
/// then "Tasks Updated" with optional counts "(X new, Y done)" when complete
/// Tappable (when updated) to open TodoDetailSheet
@available(iOS 26.0, *)
struct TodoWriteChip: View {
    let data: TodoWriteChipData
    let onTap: () -> Void

    var body: some View {
        Group {
            if data.status == .updated {
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

            if data.status == .updated {
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
        case .updating:
            ProgressView()
                .scaleEffect(0.7)
                .tint(.tronSlate)
        case .updated:
            Image(systemName: "checklist")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSlate)
        }
    }

    private var statusText: String {
        switch data.status {
        case .updating:
            return "Updating Tasks..."
        case .updated:
            var parts: [String] = []
            if data.newCount > 0 {
                parts.append("\(data.newCount) new")
            }
            if data.doneCount > 0 {
                parts.append("\(data.doneCount) done")
            }
            if parts.isEmpty {
                return "Tasks Updated"
            }
            return "Tasks Updated (\(parts.joined(separator: ", ")))"
        }
    }
}

// MARK: - TodoWrite Chip Fallback (iOS < 26)

/// Fallback chip without glass effect for older iOS versions
struct TodoWriteChipFallback: View {
    let data: TodoWriteChipData
    let onTap: () -> Void

    var body: some View {
        Group {
            if data.status == .updated {
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

            if data.status == .updated {
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
        case .updating:
            ProgressView()
                .scaleEffect(0.7)
                .tint(.tronSlate)
        case .updated:
            Image(systemName: "checklist")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSlate)
        }
    }

    private var statusText: String {
        switch data.status {
        case .updating:
            return "Updating Tasks..."
        case .updated:
            var parts: [String] = []
            if data.newCount > 0 {
                parts.append("\(data.newCount) new")
            }
            if data.doneCount > 0 {
                parts.append("\(data.doneCount) done")
            }
            if parts.isEmpty {
                return "Tasks Updated"
            }
            return "Tasks Updated (\(parts.joined(separator: ", ")))"
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("TodoWrite Chip States") {
    VStack(spacing: 16) {
        // Updating (running)
        TodoWriteChip(
            data: TodoWriteChipData(
                toolCallId: "call_0",
                newCount: 0,
                doneCount: 0,
                totalCount: 0,
                status: .updating
            ),
            onTap: { }
        )

        // Updated - no counts
        TodoWriteChip(
            data: TodoWriteChipData(
                toolCallId: "call_1",
                newCount: 0,
                doneCount: 0,
                totalCount: 3
            ),
            onTap: { }
        )

        // New only
        TodoWriteChip(
            data: TodoWriteChipData(
                toolCallId: "call_2",
                newCount: 3,
                doneCount: 0,
                totalCount: 5
            ),
            onTap: { }
        )

        // Both new and done
        TodoWriteChip(
            data: TodoWriteChipData(
                toolCallId: "call_3",
                newCount: 3,
                doneCount: 2,
                totalCount: 5
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
