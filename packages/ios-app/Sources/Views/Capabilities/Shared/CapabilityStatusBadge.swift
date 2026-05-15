import SwiftUI

// MARK: - Status Badge

/// Glass pill for capability invocation status.
@available(iOS 26.0, *)
struct CapabilityStatusBadge: View {
    let status: CapabilityInvocationStatus

    private var statusColor: Color {
        switch status {
        case .generating, .running, .paused, .approvalRequired: return .tronAmber
        case .success: return .tronSuccess
        case .error, .unavailable: return .tronError
        }
    }

    private var statusLabel: String {
        switch status {
        case .generating: return "Resolving"
        case .running: return "Running"
        case .paused: return "Paused"
        case .approvalRequired: return "Approval"
        case .success: return "Completed"
        case .error: return "Failed"
        case .unavailable: return "Unavailable"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .generating || status == .running {
                ProgressView()
                    .scaleEffect(0.55)
                    .tint(statusColor)
            } else {
                Image(systemName: status.iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            Text(statusLabel)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(statusColor.opacity(0.25)), in: Capsule())
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}
