import SwiftUI

/// In-chat chip for a RenderUI canvas.
/// Shows status and is tappable to reopen the rendered UI.
@available(iOS 26.0, *)
struct RenderUIChip: View {
    let data: RenderUIChipData
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
            Image(systemName: "rectangle.on.rectangle")
                .font(.caption)
                .foregroundStyle(data.status.color)

            Text(data.displayTitle)
                .font(.caption)
                .fontWeight(.medium)

            statusView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(data.status.color.opacity(0.15))
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch data.status {
        case .rendering:
            ProgressView()
                .controlSize(.mini)
        case .ready:
            Image(systemName: data.status.iconName)
                .font(.caption2)
                .foregroundStyle(data.status.color)
        case .error:
            Image(systemName: data.status.iconName)
                .font(.caption2)
                .foregroundStyle(data.status.color)
        }
    }
}
