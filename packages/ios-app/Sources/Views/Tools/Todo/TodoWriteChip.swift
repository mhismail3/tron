import SwiftUI

// MARK: - TodoWrite Chip (iOS 26)

/// Compact chip for TodoWrite tool calls
/// Shows "Tasks Updated" with optional counts "(X new, Y done)"
/// Tappable to open TodoDetailSheet
@available(iOS 26.0, *)
struct TodoWriteChip: View {
    let data: TodoWriteChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Checklist icon
                Image(systemName: "checklist")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronSlate)

                // Status text
                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronSlate)
                    .lineLimit(1)

                // Chevron for tappable action
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronSlate.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(Color.tronSlate.opacity(0.35)),
                        in: .capsule
                    )
            }
            .overlay(
                Capsule()
                    .strokeBorder(Color.tronSlate.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
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

// MARK: - TodoWrite Chip Fallback (iOS < 26)

/// Fallback chip without glass effect for older iOS versions
struct TodoWriteChipFallback: View {
    let data: TodoWriteChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Checklist icon
                Image(systemName: "checklist")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronSlate)

                // Status text
                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronSlate)
                    .lineLimit(1)

                // Chevron
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronSlate.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.tronSlate.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.tronSlate.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
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

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("TodoWrite Chip States") {
    VStack(spacing: 16) {
        // No counts
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

        // Done only
        TodoWriteChip(
            data: TodoWriteChipData(
                toolCallId: "call_3",
                newCount: 0,
                doneCount: 2,
                totalCount: 4
            ),
            onTap: { }
        )

        // Both new and done
        TodoWriteChip(
            data: TodoWriteChipData(
                toolCallId: "call_4",
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
