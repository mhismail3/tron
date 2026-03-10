import SwiftUI

// MARK: - QueryAgent Chip

/// In-chat chip for QueryAgent tool calls.
/// Shows query type, status, and result preview.
/// Uses indigo tint to distinguish from SubagentChip (emerald/amber).
struct QueryAgentChip: View {
    let data: QueryAgentChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Image(systemName: data.queryType.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(data.status.color)

                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(data.status.color)
                    .lineLimit(1)

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(data.status.color.opacity(0.7))
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(data.status.color.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chipStyle(data.status.color)
        .chipAccessibility(tool: "Query Agent", status: data.status.label, summary: data.queryType.displayName)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .querying:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronIndigo)
        case .success:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .error:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .querying:
            return "Querying \(data.queryType.displayName.lowercased())…"
        case .success:
            return data.queryType.displayName
        case .error:
            return "Query failed"
        }
    }
}
