import SwiftUI

// MARK: - Inherited Section

/// Collapsible section showing events inherited from parent session
@available(iOS 26.0, *)
struct InheritedSection: View {
    let events: [SessionEvent]
    let forkPointEvent: SessionEvent?
    @Binding var isExpanded: Bool
    let parentSessionId: String?
    let onFork: (String) -> Void

    /// Truncated session ID for display (first 8 chars)
    private var displaySessionId: String {
        guard let id = parentSessionId else { return "unknown" }
        return String(id.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header (always visible, entire container tappable)
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronPurple)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Inherited from")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)

                        Text(displaySessionId)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronPurple)
                    }

                    Text("\(events.count) events")
                        .font(TronTypography.mono(size: TronTypography.sizeBody2))
                        .foregroundStyle(.tronTextMuted)
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPurple.opacity(0.25)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            }

            // Expanded content
            if isExpanded {
                LazyVStack(spacing: 2) {
                    ForEach(events) { event in
                        EventRow(
                            event: event,
                            isHead: false,
                            isMuted: true,
                            showForkButton: true,
                            onFork: { onFork(event.id) }
                        )
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .background(Color.tronOverlay(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            // Fork point indicator (always visible)
            if let forkPoint = forkPointEvent {
                ForkPointIndicator(event: forkPoint)
                    .padding(.top, 12)
            }
        }
    }
}
