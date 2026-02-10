import SwiftUI

// MARK: - RenderAppUI Chip

/// In-chat chip for RenderAppUI tool calls
/// Shows real-time status updates: rendering → complete/error
/// Only tappable when complete to open canvas sheet with rendered UI
@available(iOS 26.0, *)
struct RenderAppUIChip: View {
    let data: RenderAppUIChipData
    let onTap: () -> Void

    var body: some View {
        if data.isTappable {
            // Tappable button for completed chips
            Button(action: onTap) {
                chipContent
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(tintColor.opacity(0.35)).interactive(),
                in: .capsule
            )
        } else {
            // Non-tappable view for rendering/error states
            chipContent
                .glassEffect(
                    .regular.tint(tintColor.opacity(0.35)).interactive(),
                    in: .capsule
                )
        }
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            // Status icon
            statusIcon

            // Status text
            Text(statusText)
                .font(TronTypography.filePath)
                .foregroundStyle(textColor)
                .lineLimit(1)

            // Chevron only for tappable chips
            if data.isTappable {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
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
        case .rendering:
            return "Rendering \(data.displayTitle)..."
        case .complete:
            return "\(data.displayTitle) rendered"
        case .error:
            return data.errorMessage ?? "Error generating"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .rendering:
            return .tronAmber
        case .complete:
            return .tronSuccess
        case .error:
            return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .rendering:
            return .tronAmber
        case .complete:
            return .tronSuccess
        case .error:
            return .tronError
        }
    }
}

// MARK: - Fallback for iOS < 26

/// Fallback chip without glass effect for older iOS versions
struct RenderAppUIChipFallback: View {
    let data: RenderAppUIChipData
    let onTap: () -> Void

    var body: some View {
        if data.isTappable {
            Button(action: onTap) {
                chipContent
            }
            .buttonStyle(.plain)
        } else {
            chipContent
        }
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            // Status icon
            statusIcon

            // Status text
            Text(statusText)
                .font(TronTypography.filePath)
                .foregroundStyle(textColor)
                .lineLimit(1)

            // Chevron only for tappable chips
            if data.isTappable {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .chipFill(tintColor)
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
        case .rendering: return "Rendering \(data.displayTitle)..."
        case .complete: return "\(data.displayTitle) rendered"
        case .error: return data.errorMessage ?? "Error generating"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .rendering: return .tronAmber
        case .complete: return .tronSuccess
        case .error: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .rendering: return .tronAmber
        case .complete: return .tronSuccess
        case .error: return .tronError
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
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

        // Test with no title (falls back to "App")
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
