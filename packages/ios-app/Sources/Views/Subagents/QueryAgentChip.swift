import SwiftUI

// MARK: - QueryAgent Chip

/// In-chat chip for QueryAgent tool calls.
/// Shows query type, status, and result preview.
/// Uses indigo tint to distinguish from SubagentChip (emerald/amber).
@available(iOS 26.0, *)
struct QueryAgentChip: View {
    let data: QueryAgentChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Image(systemName: data.queryType.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(textColor)

                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(tintColor.opacity(0.35)).interactive(),
            in: .capsule
        )
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
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .error:
            Image(systemName: "xmark.circle.fill")
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

    private var textColor: Color {
        switch data.status {
        case .querying: return .tronIndigo
        case .success: return .tronIndigo
        case .error: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .querying: return .tronIndigo
        case .success: return .tronIndigo
        case .error: return .tronError
        }
    }
}

// MARK: - Fallback for iOS < 26

struct QueryAgentChipFallback: View {
    let data: QueryAgentChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Image(systemName: data.queryType.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(textColor)

                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .chipFill(tintColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .querying: return "Querying \(data.queryType.displayName.lowercased())…"
        case .success: return data.queryType.displayName
        case .error: return "Query failed"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .querying: return .tronIndigo
        case .success: return .tronIndigo
        case .error: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .querying: return .tronIndigo
        case .success: return .tronIndigo
        case .error: return .tronError
        }
    }
}
