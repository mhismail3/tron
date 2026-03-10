import SwiftUI

/// Displays queued messages as removable chips above the input bar.
@available(iOS 26.0, *)
struct QueuedMessageChipsView: View {
    let queue: [QueuedMessage]
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(queue.enumerated()), id: \.element.id) { index, message in
                HStack(spacing: 8) {
                    // Position badge
                    Text("\(index + 1)")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .bold))
                        .foregroundStyle(.tronEmerald.opacity(0.5))
                        .frame(width: 18, height: 18)

                    // Truncated message text
                    Text(message.text)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(.tronEmerald.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    // Remove button
                    Button {
                        withAnimation(.tronStandard) {
                            onRemove(message.id)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                            .foregroundStyle(.tronEmerald.opacity(0.4))
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(
                    .regular.tint(Color.tronPhthaloGreen.opacity(0.15)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.tronStandard, value: queue.map(\.id))
    }
}
