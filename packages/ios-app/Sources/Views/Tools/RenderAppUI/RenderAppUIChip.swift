import SwiftUI

// MARK: - RenderAppUI Chip

/// In-chat chip for RenderAppUI tool calls
/// Shows real-time status updates: rendering → complete/error
/// Only tappable when complete to open canvas sheet with rendered UI
struct RenderAppUIChip: View {
    let data: RenderAppUIChipData
    let onTap: () -> Void

    var body: some View {
        if data.isTappable {
            Button(action: onTap) {
                chipContent
            }
            .buttonStyle(.plain)
            .chipStyle(data.status.color)
            .chipAccessibility(tool: "Render UI", status: data.status.label, summary: data.displayTitle)
        } else {
            chipContent
                .chipStyle(data.status.color)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Render UI, \(data.status.label), \(data.displayTitle)")
        }
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            statusIcon

            Text(statusText)
                .font(TronTypography.filePath)
                .foregroundStyle(data.status.color)
                .lineLimit(1)

            if data.isTappable {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(data.status.color.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .rendering:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronAmber)
        case .complete:
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
        case .rendering:
            return "Rendering \(data.displayTitle)..."
        case .complete:
            return "\(data.displayTitle) rendered"
        case .error:
            return data.errorMessage ?? "Error generating"
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("RenderAppUI States") {
    VStack(spacing: 16) {
        RenderAppUIChip(
            data: RenderAppUIChipData(
                toolCallId: "call_1",
                canvasId: "canvas_abc123",
                title: "Settings Panel",
                status: .rendering,
                errorMessage: nil
            ),
            onTap: { }
        )

        RenderAppUIChip(
            data: RenderAppUIChipData(
                toolCallId: "call_3",
                canvasId: "canvas_ghi789",
                title: "User Profile",
                status: .complete,
                errorMessage: nil
            ),
            onTap: { }
        )

        RenderAppUIChip(
            data: RenderAppUIChipData(
                toolCallId: "call_4",
                canvasId: "canvas_jkl012",
                title: "Payment Form",
                status: .error,
                errorMessage: "Error generating"
            ),
            onTap: { }
        )

        RenderAppUIChip(
            data: RenderAppUIChipData(
                toolCallId: "call_5",
                canvasId: "canvas_mno345",
                title: nil,
                status: .complete,
                errorMessage: nil
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
