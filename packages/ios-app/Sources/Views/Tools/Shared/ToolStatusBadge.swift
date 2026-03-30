import SwiftUI

// MARK: - Status Badge

/// Glass pill for tool status (completed/running/failed)
@available(iOS 26.0, *)
struct ToolStatusBadge: View {
    let status: CommandToolStatus

    private var statusColor: Color {
        switch status {
        case .running: return .tronAmber
        case .success: return .tronSuccess
        case .error: return .tronError
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .running {
                ProgressView()
                    .scaleEffect(0.55)
                    .tint(statusColor)
            } else {
                Image(systemName: status.iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(statusColor)
            }
            Text(status.label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(statusColor.opacity(0.25)), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}
